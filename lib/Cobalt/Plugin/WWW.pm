package Cobalt::Plugin::WWW;
our $VERSION = '0.10';

use 5.10.1;
use strictures 1;

use Cobalt::Common;

use POE qw/Component::Client::HTTP/;

use Moo;

has 'core' => ( is => 'rw', isa => Object, predicate => 'has_core' );

has 'opts' => ( is => 'rw', lazy => 1,
  default => sub {
    my ($self) = @_;
    return {} unless $self->has_core;
    $self->core->get_plugin_cfg($self)->{Opts}
  },
);

has 'bindaddr'  => ( is => 'rw', lazy => 1,
  predicate => 'has_bindaddr', 
  default => sub {
    my ($self) = @_;
    $self->opts->{BindAddr}
  },
);

has 'proxy' => ( is => 'rw', lazy => 1,
  predicate => 'has_proxy',
  default => sub {
    my ($self) = @_;
    $self->opts->{Proxy}
  },
);

has 'timeout'   => ( is => 'rw', lazy => 1,
  default => sub {
    my ($self) = @_;
    $self->opts->{Timeout} || 60
  },
);

has 'max_workers' => ( is => 'rw', isa => Int, lazy => 1,
  default => sub { 
    my ($self) = @_;
    $self->opts->{MaxWorkers} || 20
  },
);

has 'Requests' => ( is => 'rw', isa => HashRef,
  default => sub { {} },
);

has 'Waiting' => ( is => 'rw', isa => ArrayRef,
  default => sub { [] },
);

has 'PendingResponse' => ( is => 'rw', isa => Int,
  default => sub { 0 },
);

sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;

  $self->core( $core );

  $core->plugin_register( $self, 'SERVER',
    [ 
      'www_request',
      'www_cancel_request',
      
      'www_push_pending',
    ],
  );
    
  POE::Session->create(
    object_states => [
      $self => [
        '_start',
        'ht_response',
        'ht_post_request',
      ],
    ],
  );

  $core->log->info("Loaded WWW interface; $VERSION");

  return PLUGIN_EAT_NONE
}

sub Cobalt_unregister {
  my ($self, $core) = splice @_, 0, 2;

  my $sess_alias = 'www_'.$core->get_plugin_alias($self);  
  $poe_kernel->alias_remove( $sess_alias );

  delete $core->Provided->{www_request};

  $core->log->info("Unregistered");
  
  return PLUGIN_EAT_NONE
}

sub Bot_www_request {
  my ($self, $core) = splice @_, 0, 2;
  my $request = ${ $_[0] };
  my $event  = defined $_[1] ? ${$_[1]} : undef ;
  my $args = defined $_[2] ? ${$_[2]} : undef ;

  unless ($request && $request->isa('HTTP::Request')) {
    $core->log->warn(
      "www_request received but no request at "
      .join ' ', (caller)[0,2]
    );
  }
  
  unless ($event) {
    ## no event at all is legitimate
    $event = 'www_not_handled';
  }
  
  $args = [] unless $args;
  my @p = ( 'a' .. 'f', 0 .. 9 );
  my $tag = join '', map { $p[rand@p] } 1 .. 5;
  $tag .= $p[rand@p] while exists $self->Requests->{$tag};

  $self->Requests->{$tag} = {
    Event     => $event,
    Args => $args,
    Request   => $request,
  };

  ## Push to pending
  my $pending = $self->Waiting;
  push(@$pending, $tag);

  $core->log->debug("www_request issue $tag -> $event");
  
  $core->send_event( 'www_push_pending' );
  
  return PLUGIN_EAT_ALL
}

sub Bot_www_push_pending {
  my ($self, $core) = splice @_, 0, 2;

  my $pending = $self->Waiting;
  return unless @$pending;
  
  my $ccount = $self->PendingResponse;

  if ($ccount >= $self->max_workers) {
    my $pcount = @$pending;
    $core->log->debug(
      "Throttling (r $ccount / w $pcount)"
    );
    $core->timer_set( 2,
      { Event => 'www_push_pending' },
      'WWWPLUG_PUSH_PENDING'
    );
  } else {
    my $tag = shift @$pending;
    
    my $this_req = $self->Requests->{$tag};
    my $request  = $this_req->{Request};

    $core->log->debug("Posting request to HTTP component");
    
    my $sess_alias = 'www_'.$core->get_plugin_alias($self);
    $poe_kernel->call( $sess_alias, 
      'ht_post_request',
      $request, $tag
    );
  
    $self->increase_pending;
    
    if (@$pending) {
      ## push_pending until we're either done or hit our limit
      $core->send_event( 'www_push_pending' );
    }
  }

  return PLUGIN_EAT_ALL
}

sub ht_post_request {
  ## Bridge to make sure response gets delivered to correct session
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my ($request, $tag) = @_[ARG0, ARG1];
  my $core = $self->core;
  ## Post the ::Request
  my $ht_alias = 'ht_'.$core->get_plugin_alias($self);
  $kernel->post( $ht_alias, 
      'request', 'ht_response', 
      $request, $tag
  );
}

sub Bot_www_cancel_request {
  my ($self, $core) = splice @_, 0, 2;
  my $tag = ${ $_[0] };
  
  my $this_req = delete $self->Requests->{$tag} || return;
  my $request = $this_req->{Request};
  
  my $pending = $self->Waiting;
  if ($tag ~~ @$pending) {
    ## This request is still sitting in the Waiting room.
    my $i;
    ++$i until $i > (scalar @$pending - 1)
      or $pending->[$i] eq $tag;
    splice(@$pending, $i, 1)
      if defined $pending->[$i]
      and $pending->[$i] eq $tag;
  } else {
    ## This request has fired.
    my $ht_alias = 'ht_'.$core->get_plugin_alias($self);
    $poe_kernel->post( $ht_alias,
      'cancel', $request
    );
    $self->decrease_pending;
  }
  
  $core->log->debug("Cancelled www_request $tag");
  
  return PLUGIN_EAT_ALL
}

sub _start {
  my ($self, $kernel) = @_[OBJECT, KERNEL];

  my $core = $self->core;

  my $sess_alias = 'www_'.$core->get_plugin_alias($self);
  $kernel->alias_set( $sess_alias );

  my %opts;
  $opts{BindAddr} = $self->bindaddr if $self->has_bindaddr;
  $opts{Proxy}    = $self->proxy    if $self->has_proxy;
  $opts{Timeout}  = $self->timeout;

  ## Create "ht_${plugin_alias}" session
  POE::Component::Client::HTTP->spawn(
    FollowRedirects => 5,
    Agent => __PACKAGE__,
    Alias => 'ht_'.$core->get_plugin_alias($self),
    %opts,
  );
  
  $core->Provided->{www_request} = __PACKAGE__ ;
}

sub ht_response {
  my ($self, $kernel) = @_[OBJECT, KERNEL];
  my ($req_pk, $resp_pk) = @_[ARG0, ARG1];

  $self->decrease_pending;
  
  my $core = $self->core;
  
  my $response = $resp_pk->[0];
  my $tag  = $req_pk->[1];

  my $this_req = delete $self->Requests->{$tag};
  
  my $event = $this_req->{Event};
  my $args  = $this_req->{Args};
  
  $core->log->debug("ht_response dispatch: $event ($tag)");

  my $content = $response->is_success ?
      $response->decoded_content
      : $response->message;

  $core->send_event($event, $content, $response, $args);
}

sub decrease_pending {
  my ($self) = @_;
  my $pending = $self->PendingResponse;
  return if !$pending or $pending == 0;
  $self->PendingResponse( --$pending )
}

sub increase_pending {
  my ($self) = @_;
  my $pending = $self->PendingResponse;
  $self->PendingResponse( ++$pending );
}

1;
__END__

=pod

=head1 NAME

Cobalt::Plugin::WWW - Asynchronous HTTP requests from Cobalt plugins

=head1 SYNOPSIS

  ## Send your request, specify an event to handle response:
  use HTTP::Request;
  my $request = HTTP::Request->new(
    'GET',
    'http://www.cobaltirc.org'
  );
  
  $core->send_event( 'www_request',
    $request,
    'myplugin_resp_recv',
    [ $some, $args ]
  );
  
  ## Handle the response:
  sub Bot_myplugin_resp_recv {
    my ($self, $core) = splice @_, 0, 2;
    
    ## Content:
    my $content  = ${ $_[0] };
    ## HTTP::Response object:
    my $response = ${ $_[1] };
    ## Attached arguments array reference:
    my $args_arr = ${ $_[2] };
    
    return PLUGIN_EAT_ALL
  }

=head1 DESCRIPTION

This plugin provides an easy interface to asynchronous HTTP requests; it 
bridges Cobalt's plugin pipeline and L<POE::Component::Client::HTTP> to 
provide responses to B<Bot_www_request> events.

The request should be a L<HTTP::Request> object.

Inside the response handler, $_[1] will contain the L<HTTP::Response> 
object; $_[0] is the undecoded content if the request was successful or 
some error from L<HTTP::Status> if not.

Arguments can be attached to the request event and retrieved in the 
handler via $_[2] -- this is usually an array reference, but anything 
that fits in a scalar will do.

Plugin authors should check for the boolean value of B<< 
$core->Provided->{www_request} >> and possibly fall back to using LWP 
with a short timeout if they'd like to continue to function if this 
plugin is B<not> loaded.

=head1 SEE ALSO

L<POE::Component::Client::HTTP>

L<HTTP::Request>

L<HTTP::Response>

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

L<http://www.cobaltirc.org>

=cut
