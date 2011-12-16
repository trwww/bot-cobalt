package Cobalt::Plugin::Auth;

use 5.12.1;
use strict;
use warnings;

use Object::Pluggable::Constants qw/ :ALL /;

## Commands:


sub new {
  my $class = shift;
  my $self = {};
  bless($self,$class);
  return $self
}

sub Cobalt_register {
  my ($self, $core) = @_;

  $core->plugin_register($self, 'SERVER',
    [ 'public_msg' ],
  );

  $core->log->info(__PACKAGE__." registered");
  return PLUGIN_EAT_NONE
}

sub Cobalt_unregister {
  my ($self, $core) = @_;
  $core->log->info("Unregistering core IRC plugin");
  return PLUGIN_EAT_NONE
}


sub Bot_private_msg {
  my ($self, $core) = splice @_, 0, 2;
  my $msg = ${ shift(@_) };

  my $txt = $msg->{message};

  my $resp;

  given ($txt) {

  }

  if ($resp) {
    ## FIXME NOTICE type
    $core->send_event( 'send_to_context',
      {
        context => $msg->{context},
        target => $msg->{src_nick},
        txt => $resp,
      }
    );    
  }

  return PLUGIN_EAT_NONE
}

1;
