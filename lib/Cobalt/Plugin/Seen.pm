package Cobalt::Plugin::Seen;
our $VERSION = '0.001';

## FIXME nick changes?

use Cobalt::Common;
use Cobalt::DB;

use constant {
  TIME     => 0,
  ACTION   => 1,
  CHANNEL  => 2,
  USERNAME => 3,
  HOST     => 4,
  META     => 5,
};

sub new { bless {}, shift }

sub parse_nick {
  my ($self, $context, $nickname) = @_;
  my $core = $self->{core};
  my $casemap = $core->get_irc_casemap($context) || 'rfc1459';
  return lc_irc($nickname, $casemap)
}

sub retrieve {
  my ($self, $context, $nickname) = @_;
  $nickname = $self->parse_nick($context, $nickname);

  my $thisbuf = $self->{Buf}->{$context} // {};

  my $core = $self->{core};

  ## attempt to get from internal hashes
  my($last_ts, $last_act, $last_chan, $last_user, $last_host);

  my $ref;

  if (exists $self->{Buf}->{$context}->{$nickname}) {
    $ref = $self->{Buf}->{$context}->{$nickname};
  } else {
    my $db = $self->{SDB};
    unless ($db->dbopen) {
      $core->log->warn("dbopen failed in retrieve; cannot open SeenDB");
      return
    }
    ## context%nickname
    my $thiskey = $context .'%'. $nickname;
    $ref = $db->get($thiskey);
    $db->dbclose;
  }

  return unless defined $ref and ref $ref;

  $last_ts   = $ref->{TS};
  $last_act  = $ref->{Action};
  $last_chan = $ref->{Channel};
  $last_user = $ref->{Username};
  $last_host = $ref->{Host};
  my $meta = $ref->{Meta} // {};

  ## fetchable via constants
  ## TIME, ACTION, CHANNEL, USERNAME, HOST
  return($last_ts, $last_act, $last_chan, $last_user, $last_host, $meta)
}

sub updatedb {
  my ($self) = @_;
  ## called by seendb_update timer
  ## update db from hashes and trim hashes appropriately
  my $buf  = $self->{Buf};
  my $db   = $self->{SDB};
  my $core = $self->{core};

  unless ($db->dbopen) {
    $core->log->warn("dbopen failed in update; cannot update SeenDB");
    return
  }  
  
  CONTEXT: for my $context (keys %$buf) {
    NICK: for my $nickname (keys %{ $buf->{$context} }) {
      ## pull this one out:
      my $thisbuf = delete $buf->{$context}->{$nickname};
      next NICK unless ref $thisbuf;
      ## write it to db:
      my $thiskey = $context .'%'. $nickname;
      $db->put($thiskey, $thisbuf);
    }
  } ## CONTEXT
  
  $db->dbclose;
  return 1
}


sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;
  $self->{core} = $core;
    
  my $pcfg = $core->get_plugin_cfg($self);
  my $seendb_path = $pcfg->{PluginOpts}->{SeenDB}
                    || "seen.db" ;
  $seendb_path = $core->var ."/". $seendb_path ;

  $core->log->debug("Opening SeenDB at $seendb_path");

  $self->{Buf} = { };
  
  $self->{BufDirty} = { };
  
  $self->{SDB} = Cobalt::DB->new(
    File => $seendb_path,
  );
  
  my $rc = $self->{SDB}->dbopen;
  $self->{SDB}->dbclose;
  die "Unable to open SeenDB at $seendb_path"
    unless $rc;

  $core->plugin_register( $self, 'SERVER', 
    [ qw/
    
      public_cmd_seen
      
      nick_changed      
      user_joined
      user_left
      user_quit
      
      seendb_update
      
    / ],
  );
  
  $core->timer_set( 6,
    ## update seendb out of hash
    {
      Event => 'seendb_update',
    },
    'SEENDB_WRITE'
  );
  
  $core->log->info("Loaded ($VERSION)");
  
  return PLUGIN_EAT_NONE
}

sub Cobalt_unregister {
  my ($self, $core) = splice @_, 0, 2;
  $core->log->info("Unloaded");
  return PLUGIN_EAT_NONE
}

sub Bot_seendb_update {
  my ($self, $core) = splice @_, 0, 2;

  return PLUGIN_EAT_ALL unless $self->{BufDirty};

  $self->updatedb;

  $self->{BufDirty} = 0;

  $core->timer_set( 6,
    {
      Event => 'seendb_update',
    },
  );  
  return PLUGIN_EAT_ALL
}

sub Bot_user_joined {
  my ($self, $core) = splice @_, 0, 2;
  my $context = ${ $_[0] };
  my $join    = ${ $_[1] };

  my $nick = $join->{src_nick};
  my $user = $join->{src_user};
  my $host = $join->{src_host};
  my $chan = $join->{channel};

  $self->{BufDirty} = 1;
  
  $nick = $self->parse_nick($nick);
  $self->{Buf}->{$context}->{$nick} = {
    TS => time(),
    Action   => 'join',
    Channel  => $chan,
    Username => $user,
    Host     => $host,
  };
  
  return PLUGIN_EAT_NONE
}

sub Bot_user_left {
  my ($self, $core) = splice @_, 0, 2;
  my $context = ${ $_[0] };
  my $part    = ${ $_[1] };
  
  my $nick = $part->{src_nick};
  my $user = $part->{src_user};
  my $host = $part->{src_host};
  my $chan = $part->{channel};

  $self->{BufDirty} = 1;

  $nick = $self->parse_nick($nick);
  $self->{Buf}->{$context}->{$nick} = {
    TS => time(),
    Action   => 'part',
    Channel  => $chan,
    Username => $user,
    Host     => $host,
  };

  return PLUGIN_EAT_NONE
}

sub Bot_user_quit {
  my ($self, $core) = splice @_, 0, 2;
  my $context = ${ $_[0] };
  my $quit    = ${ $_[1] };
  
  my $nick = $quit->{src_nick};
  my $user = $quit->{src_user};
  my $host = $quit->{src_host};
  my $chan = $quit->{channel};

  $self->{BufDirty} = 1;

  $nick = $self->parse_nick($nick);
  $self->{Buf}->{$context}->{$nick} = {
    TS => time(),
    Action   => 'quit',
    Channel  => $chan,
    Username => $user,
    Host     => $host,
  };
  
  return PLUGIN_EAT_NONE
}

sub Bot_nick_changed {
  my ($self, $core) = splice @_, 0, 2;
  my $context = ${ $_[0] };
  my $nchange = ${ $_[1] };
  return PLUGIN_EAT_NONE if $nchange->{equal};
  
  my $old = $nchange->{old};
  my $new = $nchange->{new};
  
  my $irc = $core->get_irc_obj($context);
  my $src = $irc->nick_long_form($new) || $new;
  my ($nick, $user, $host) = parse_user($src);
  
  my $first_common = $nchange->{common}->[0];
  
  $self->{Buf}->{$context}->{$old} = {
    TS => time(),
    Action   => 'nchange',
    Channel  => $first_common,
    Username => $user || 'unknown',
    Host     => $host || 'unknown',
    Meta     => { To => $new },
  };
  
  $self->{Buf}->{$context}->{$new} = {
    TS => time(),
    Action   => 'nchange',
    Channel  => $first_common,
    Username => $user || 'unknown',
    Host     => $host || 'unknown',
    Meta     => { From => $old },
  };
  
  return PLUGIN_EAT_NONE
}

sub Bot_public_cmd_seen {
  my ($self, $core) = splice @_, 0, 2;
  my $context = ${ $_[0] };
  my $msg     = ${ $_[1] };
  
  my $channel = $msg->{channel};
  my $nick    = $msg->{src_nick};
  
  my $targetnick = $msg->{message_array}->[0];
  
  unless ($targetnick) {
    $core->send_event( 'send_message', 
      $context,
      $channel,
      "Need a nickname to look for, $nick"
    );
    return PLUGIN_EAT_NONE
  }
  
  my @ret = $self->retrieve($context, $targetnick);
  
  unless (@ret) {
    $core->send_event( 'send_message',
      $context,
      $channel,
      "${nick}: I don't know anything about $targetnick"
    );
    return PLUGIN_EAT_NONE
  }
  
  my ($last_ts, $last_act, $last_user, $last_host, $last_chan, $meta) = 
    @ret[TIME, ACTION, USERNAME, HOST, CHANNEL, META];

  my $ts_delta = time() - $last_ts ;
  my $ts_str   = secs_to_timestr($ts_delta);

  my $resp;
  given ($last_act) {
    when ("quit") {
      $resp = 
        "$targetnick was last seen quitting from $last_chan $ts_str ago";
    }
    
    when ("join") {
      $resp =
        "$targetnick was last seen joining $last_chan $ts_str ago";
    }
    
    when ("part") {
      $resp =
        "$targetnick was last seen leaving $last_chan $ts_str ago";
    }
    
    when ("nchange") {
      if      ($meta->{From}) {
        $resp = 
          "$targetnick was last seen changing nicknames from "
          .$meta->{From}.
          " $ts_str ago";
      } elsif ($meta->{To}) {
        $resp = 
          "$targetnick was last seen changing nicknames from "
          .$meta->{To}.
          " $ts_str ago";
      }
    }
  }  

  $core->send_event( 'send_message', 
    $context,
    $channel,
    $resp
  );  
  
  return PLUGIN_EAT_NONE
}

1;
__END__

=pod

=head1 NAME

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 AUTHOR

=cut
