package Bot::Cobalt::Plugin::PluginMgr;
our $VERSION = '0.010_01';

## handles and eats: !plugin

use 5.10.1;
use strict;
use warnings;

use Object::Pluggable::Constants qw/ :ALL /;

use Bot::Cobalt;
use Bot::Cobalt::Utils qw/ rplprintf /;
use Bot::Cobalt::Conf;

use Scalar::Util qw/blessed/;

sub new { bless {}, shift }

sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;

  register( $self, 'SERVER',
    'public_cmd_plugin',
  );

  logger->info("Registered");

  return PLUGIN_EAT_NONE
}

sub Cobalt_unregister {
  my ($self, $core) = splice @_, 0, 2;

  logger->info("Unregistered");

  return PLUGIN_EAT_NONE
}

sub _unload {
  my ($self, $alias) = @_;

  my $resp;

  my $plug_obj = core()->plugin_get($alias);
  my $plugisa = ref $plug_obj || return "_unload broken, no PLUGISA?";

  unless ($alias) {
    $resp = "Bad syntax; no plugin alias specified";
  } elsif (! $plug_obj ) {

    $resp = rplprintf( core()->lang->{RPL_PLUGIN_UNLOAD_ERR},
              plugin => $alias,
              err => 'No such plugin found, is it loaded?' 
    );

  } elsif (! core()->is_reloadable($alias) ) {

    $resp = rplprintf( core()->lang->{RPL_PLUGIN_UNLOAD_ERR},
              plugin => $alias,
              err => "Plugin $alias is marked as non-reloadable",
   );

  } else {
    logger->info("Attempting to unload $alias ($plugisa) per request");

    if ( core()->plugin_del($alias) ) {
      delete core()->PluginObjects->{$plug_obj};

      ## ask core to clean up symbol table:
      core()->unloader_cleanup($plugisa);

      ## also cleanup our config if there is one:
      delete core()->cfg->{plugin_cf}->{$alias};

      ## and timers:
      core()->timer_del_alias($alias);
      
      $resp = rplprintf( core()->lang->{RPL_PLUGIN_UNLOAD}, 
        plugin => $alias
      );
    } else {
      $resp = rplprintf( core()->lang->{RPL_PLUGIN_UNLOAD_ERR},
        plugin => $alias, 
        err => 'Unknown failure'
      );
    }

  }

  return $resp
}

sub _load_module {
  ## _load_module( 'Auth', 'Bot::Cobalt::Plugin::Auth' ) f.ex
  ## returns a response string for irc
  my ($self, $alias, $module) = @_;

  my $err;
  ## FIXME needs to be converted to use core->load_plugin
  {
    local $@;
    eval "require $module";
    $err = $@ if $@;
  }

  if ($err) {
    ## 'require' failed
    my $err = $@;
    logger->warn("Plugin load failure; $err");
    
    core()->unloader_cleanup($module);

    return rplprintf( core()->lang->{RPL_PLUGIN_ERR},
      plugin => $alias,
      err => "Module $module cannot be found/loaded: $err",
    );
  } else {
    ## module found, attempt to load it
    unless ( $module->can('new') ) {
      return rplprintf( core()->lang->{RPL_PLUGIN_ERR},
        plugin => $alias,
        err => "Module $module doesn't appear to have new()",
      );
    }

  }

  my $obj = $module->new();
  unless ($obj && blessed $obj) {
      return rplprintf( core()->lang->{RPL_PLUGIN_ERR},
        plugin => $alias,
        err => "Constructor for $module returned junk",
      );
  }

  ## store plugin objects:
  core()->PluginObjects->{$obj} = $alias;

  ## plugin_add returns # of plugins in pipeline on success:
  my $loaded = core()->plugin_add( $alias, $obj );
  if ($loaded) {
    unless ( core()->is_reloadable($alias, $obj) ) {
      logger->debug("$alias flagged non-reloadable");
    }
      
    my $modversion = $obj->can('VERSION') ? $obj->VERSION : 1 ;
      
    return rplprintf( core()->lang->{RPL_PLUGIN_LOAD},
      plugin  => $alias,
      module  => $module,
      version => $modversion,
    );
  } else {
    ## Couldn't plugin_add
    logger->error("plugin_add failure for $alias");

    ## run cleanup  
    core()->unloader_cleanup($module);
    delete core()->PluginObjects->{$obj};

    return rplprintf( core()->lang->{RPL_PLUGIN_ERR},
      plugin => $alias,
      err => "Unknown plugin_add failure",
    );
  }

}

sub _load {
  my ($self, $alias, $module, $reload) = @_;

  return "Bad syntax; usage: load <alias> [module]"
    unless $alias;

  ## check list to see if alias is already loaded
  my $pluglist = core()->plugin_list;

  return "Plugin already loaded: $alias"
    if $alias ~~ [ keys %$pluglist ] ;

  my $pluginscf = core()->cfg->{plugins};  # plugins.conf

  if ($module) {
    ## user (or 'reload') specified a module for this alias
    ## it could still have conf opts specified:
    $self->_load_conf($alias, $module, $pluginscf);
    return $self->_load_module($alias, $module);

  } else {

    unless (exists $pluginscf->{$alias}
            && ref $pluginscf->{$alias} eq 'HASH') {
      return rplprintf( core()->lang->{RPL_PLUGIN_ERR},
        {
          plugin => $alias,
          err => "No '${alias}' plugin found in plugins.conf",
        }
      );
    }

    my $pkgname = $pluginscf->{$alias}->{Module};
    unless ($pkgname) {
      return rplprintf( core()->lang->{RPL_PLUGIN_ERR},
        {
          plugin => $alias,
          err => "No Module specified in plugins.conf for plugin '${alias}'",
        }
      );
    }

    ## read conf into core:
    $self->_load_conf($alias, $pkgname, $pluginscf);

    ## load the plugin:
    return $self->_load_module($alias, $pkgname);
  }

}

sub _load_conf {
  my ($self, $alias, $pkgname, $pluginscf) = @_;

  $pluginscf = $self->_read_core_plugins_conf unless $pluginscf;

  ## (re)load this plugin's configuration before loadtime
  my $cconf = Bot::Cobalt::Conf->new(
    etc => core()->cfg->{path}
  );

  ## use our current plugins.conf (not a rehash)
  my $thisplugcf = $cconf->_read_plugin_conf($alias, $pluginscf);
  $thisplugcf = {} unless ref $thisplugcf;

  ## directly fuck with core's cfg hash:
  core()->cfg->{plugin_cf}->{$alias} = $thisplugcf;
}


sub Bot_public_cmd_plugin {
  my ($self, $core) = splice @_, 0, 2;
  my $msg = ${$_[0]};
  my $context = $msg->context;

  my $chan = $msg->channel;
  my $nick = $msg->src_nick;
  
  my $pcfg = core()->get_plugin_cfg( $self );

  ## default to superuser-only:
  my $required_lev = $pcfg->{PluginOpts}->{LevelRequired} // 9999;

  my $resp;

  my $operation = $msg->message_array->[0];

  unless ( core()->auth->level($context, $nick) >= $required_lev ) {
    $resp = rplprintf( core()->lang->{RPL_NO_ACCESS}, { nick => $nick } );
  } else {
  
    ## FIXME proper cmd dispatcher for all this crap
    given ( lc($operation || '') ) {
      when ('load') {
        ## syntax: !plugin load <alias>, !plugin load <alias> <module>
        my $alias  = $msg->message_array->[1];
        my $module = $msg->message_array->[2];
        $resp = $self->_load($alias, $module);
      }

      when ('unload') {
        ## syntax: !plugin unload <alias>
        my $alias = $msg->message_array->[1];
        $resp = $self->_unload($alias) || "Strange, no reply from _unload?";
      }

      when ('reload') {
        ## syntax: !plugin reload <alias>
        $resp = $self->_cmd_plug_reload($msg);
      }

      when ('list') {
        $resp = $self->_cmd_plug_list($msg);
      }

      ## shouldfix; reordering via ::Pipeline?

      default { 
        $resp = "Valid PluginMgr commands: list / load / unload / reload"
      }
    }

  }

  broadcast('message', $context, $chan, $resp) if defined $resp;

  return PLUGIN_EAT_ALL
}

sub _cmd_plug_list {
  my ($self, $msg) = @_;
  
  my $pluglist = core()->plugin_list;
  
  my @loaded = sort keys %$pluglist;

  my $str;
  while (my $plugin_alias = shift @loaded) {
    $str .= ' ' . $plugin_alias;

    if ($str && (length($str) > 300 || !@loaded) ) {
      ## either this string has gotten long or we're done
      broadcast( 'message', $msg->context, $msg->channel, $str );
      $str = '';
    }
  }
}

sub _cmd_plug_reload {
  my ($self, $msg) = @_;

  my $alias = $msg->message_array->[1];

  my $plug_obj = core()->plugin_get($alias);

  my $resp;
  if (!$alias) {

    broadcast( 'message', $msg->context, $msg->channel,
      "Bad syntax; no plugin alias specified"
    );
    
    return

  } elsif (!$plug_obj) {

    broadcast( 'message', $msg->context, $msg->channel,
      rplprintf( core()->lang->{RPL_PLUGIN_UNLOAD_ERR},
        plugin => $alias,
        err => 'No such plugin found, is it loaded?' 
      )
    );
    
    return

  } elsif (core()->State->{NonReloadable}->{$alias}) {

    broadcast( 'message', $msg->context, $msg->channel,
      rplprintf( core()->lang->{RPL_PLUGIN_UNLOAD_ERR},
          plugin => $alias,
          err => "Plugin $alias is marked as non-reloadable",
      )
    );
    
    return
  }

   ## call _unload and send any response from there
  my $unload_resp = $self->_unload($alias);

  broadcast( 'message', $msg->context, $msg->channel, $unload_resp );

  my $pkgisa = ref $plug_obj;

  return $self->_load($alias, $pkgisa);
}

1;
__END__

=pod

=head1 NAME

Bot::Cobalt::Plugin::PluginMgr - IRC plugin manager

=head1 SYNOPSIS

  !plugin list
  !plugin load MyPlugin
  !plugin load MyPlugin Bot::Cobalt::Plugin::User::MyPlugin
  !plugin reload MyPlugin
  !plugin unload MyPlugin

=head1 DESCRIPTION

This is a fairly simplistic online plugin manager.

Required level defaults to 9999 (standard-auth superusers) unless 
the LevelRequired option is specified in PluginMgr's plugins.conf 
B<Opts> directive:

  PluginMgr:
    Module: Bot::Cobalt::Plugin::PluginMgr
    Opts:
      ## '3' is legacy darkbot 'administrator':
      LevelRequired: 3

=head1 COMMANDS

B<PluginMgr> responds to the C<!plugin> command:

  <JoeUser> !plugin reload Shorten

=head2 list

Lists the aliases of all currently loaded plugins.

=head2 load

Load a specified plugin.

If the plugin has a C<plugins.conf> directive, the alias can be 
specified by itself; the Module specified in C<plugins.conf> will be 
used:

  <JoeUser> !plugin load Shorten

Otherwise, a module must be specified:

  <JoeUser> !plugin load Shorten Bot::Cobalt::Plugin::Extras::Shorten

If the module's alias has a Config or Opts specified, they will 
also be loaded.

=head2 unload

Unload a specified plugin.

The only argument is the plugin's alias.

=head2 reload

Unload and re-load the specified plugin, rehashing any applicable 
configuration.


=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

=cut
