package Bot::Cobalt::Plugin::Extras::Money;
our $VERSION = '0.200_46';

use 5.10.1;
use Bot::Cobalt::Common;

use URI::Escape;
use HTTP::Request;

sub new { bless {}, shift }

sub Cobalt_register {
  my ($self, $core) = splice @_, 0, 2;
  $self->{core} = $core;
  $self->{Cached} = {};
  $core->plugin_register( $self, 'SERVER',
    [
      'public_cmd_currency',
      'public_cmd_cc',
      'public_cmd_money',
      
      'currencyconv_rate_recv',
      'currencyconv_expire_cache',
    ],
  );
  $core->log->info("Loaded: cc money currency");

  $core->timer_set( 1200,
    {
      Event => 'currencyconv_expire_cache',
      Alias => $core->get_plugin_alias($self),
    },
    'CURRENCYCONV_CACHE'
  );

  return PLUGIN_EAT_NONE 
}

sub Cobalt_unregister {
  my ($self, $core) = splice @_, 0, 2;
  $core->log->info("Unloaded");
  return PLUGIN_EAT_NONE
}

sub Bot_currencyconv_expire_cache {
  my ($self, $core) = splice @_, 0, 2;
  
  for my $fromto (keys %{ $self->{Cached} }) {
    my $delta = time - $self->{Cached}->{$fromto}->{TS};
    if ($delta >= 1200) {
      $core->log->debug("expired cached: $fromto");
      delete $self->{Cached}->{$fromto};
    }
  }
  
  $core->timer_set( 1200,
    {
      Event => 'currencyconv_expire_cache',
      Alias => $core->get_plugin_alias($self),
    },
    'CURRENCYCONV_CACHE'
  );
  
  return PLUGIN_EAT_ALL;
}

sub Bot_public_cmd_currency {
  my ($self, $core) = splice @_, 0, 2;
  my $msg     = ${ $_[0] };
  my $context = $msg->context;
  
  my $channel = $msg->channel;

  my $message = $msg->message_array;
  my ($value, $from, undef, $to) = @$message;
  
  unless ($value && $from && $to) {
    $core->send_event( 'send_message', $context, $channel,
      "Syntax: !cc <value> <abbrev> TO <abbrev>"
    );
    return PLUGIN_EAT_ALL
  }
  
  my $valid_val    = qr/^(\d+)?\.?(\d+)?$/;
  my $valid_abbrev = qr/^[a-zA-Z]{3}$/;

  unless ($value =~ $valid_val) {
    $core->send_event( 'send_message', $context, $channel,
      "$value is not a valid quantity."
    );  
    return PLUGIN_EAT_ALL
  }
  
  unless ($from =~ $valid_abbrev && $to =~ $valid_abbrev) {
    $core->send_event( 'send_message', $context, $channel,
      "Currency codes must be three-letter abbreviations."
    );
    return PLUGIN_EAT_ALL
  }

  $self->_request_conversion_rate(
    uc($from), uc($to), $value, $context, $channel
  );
  
  return PLUGIN_EAT_ALL
}

sub Bot_public_cmd_cc    { Bot_public_cmd_currency(@_) }
sub Bot_public_cmd_money { Bot_public_cmd_currency(@_) }

sub Bot_currencyconv_rate_recv {
  my ($self, $core) = splice @_, 0, 2;
  my $response = ${ $_[1] };
  my $args     = ${ $_[2] };
  my ($value, $context, $channel, $from, $to) = @$args;
  
  unless ($response->is_success) {
    if ($response->code == 500) {
      $core->send_event( 'send_message', $context, $channel,
        "Received error 500; is your currency code valid?"
      );
    } else {
      $core->send_event( 'send_message', $context, $channel,
        "HTTP failed: ".$response->code
      );
    }
    return PLUGIN_EAT_ALL
  }

  my $content = $response->decoded_content;
  
  my($rate,$converted);
  if ( $content =~ /<double.*>(.*)<\/double>/i ) {
    $rate = $1||1;
    $converted = $value * $rate ;
  } else {
    $core->send_event( 'send_message', $context, $channel,
      "Failed to retrieve currency conversion ($from -> $to)"
    );
    return PLUGIN_EAT_ALL
  }

  my $cachekey = "${from}-${to}";
  $self->{Cached}->{$cachekey} = {
    Rate => $rate,
    TS   => time,
  };
  
  $core->send_event( 'send_message', $context, $channel,
    "$value $from == $converted $to"
  );
  
  return PLUGIN_EAT_ALL
}

sub _request_conversion_rate {
  my ($self, $from, $to, $value, $context, $channel) = @_;
  return unless $from and $to;

  my $core = $self->{core};

  ## maybe cached
  my $cachekey = "${from}-${to}";
  if ($self->{Cached}->{$cachekey}) {
    my $cachedrate = $self->{Cached}->{$cachekey}->{Rate};
    my $converted = $value * $cachedrate;
    $core->send_event( 'send_message', $context, $channel,
      "$value $from == $converted $to"
    );
    return 1
  }

  my $uri = 
     "http://www.webservicex.net/CurrencyConvertor.asmx"
    ."/ConversionRate?FromCurrency=${from}&ToCurrency=${to}";
  
  if ($core->Provided->{www_request}) {
    my $req = HTTP::Request->new( 'GET', $uri ) || return undef;
    $core->send_event( 'www_request',
      $req,
      'currencyconv_rate_recv',
      [ $value, $context, $channel, $from, $to ],
    );
  } else {
    $core->send_event( 'send_message', $context, $channel,
      "No async HTTP available; try loading Bot::Cobalt::Plugin::WWW"
    );
  }
}

1;
__END__

=pod

=head1 NAME

Bot::Cobalt::Plugin::Extras::Money - currency conversion plugin

=head1 USAGE

  !cc 20 NZD to USD
  <cobalt2> 20 NZD == 16.564 USD

=head1 DESCRIPTION

Uses L<http://www.webservicex.net> to handle currency conversion.

Requires L<Bot::Cobalt::Plugin::WWW>

=head1 AUTHOR

Jon Portnoy <avenj@cobaltirc.org>

L<http://www.cobaltirc.org>

=cut