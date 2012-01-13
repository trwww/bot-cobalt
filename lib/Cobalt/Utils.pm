package Cobalt::Utils;

our $VERSION = '0.12';

use 5.12.1;
use strict;
use warnings;

use Crypt::Eksblowfish::Bcrypt;

require Exporter;
our @ISA = qw(Exporter);

our @EXPORT_OK = qw/
  secs_to_timestr
  timestr_to_secs

  mkpasswd
  passwdcmp

  color

  rplprintf
/;

our %EXPORT_TAGS = (
  ALL => [ @EXPORT_OK ],
);


## String formatting, usually for langsets:
sub rplprintf {
  my ($string, $vars) = @_;
  return unless $string;
  $vars = {} unless $vars;
  ## rplprintf( $string, $vars )
  ##
  ## variables can be terminated with % or a space:
  ## rplprintf( "Error for %user%: %err")
  ##
  ## used for formatting lang RPLs
  ## $vars should be a hash keyed by variable, f.ex:
  ##   'user' => $username,
  ##   'err'  => $error,

  sub _repl {
    ## _repl($1, $2, $vars)
    my ($orig, $match, $vars) = @_;
    return $orig unless defined $vars->{$match};
    my $replace = $vars->{$match};
    return $replace
  }

  my $regex = qr/(%([^\s%]+)%?)/;

  $string =~ s/$regex/_repl($1, $2, $vars)/ge;

  return $string  
}


## IRC color codes:
sub color {
  ## color($format, $str)
  ## implements mirc formatting codes, against my better judgement
  ## if format is unspecified, returns NORMAL
  
  ## interpolate bold, reset to NORMAL after:
  ## $str = color('bold') . "Text" . color;
  ##  -or-
  ## format specified strings, resetting NORMAL after:
  ## $str = color('bold', "Some text"); # bold text ending in normal

  ## mostly borrowed from IRC::Utils

  my $format = uc(shift || 'normal');
  my $str = shift;
  my %colors = (
    NORMAL      => "\x0f",

    BOLD        => "\x02",
    UNDERLINE   => "\x1f",
    REVERSE     => "\x16",
    ITALIC      => "\x1d",

    WHITE       => "\x0300",
    BLACK       => "\x0301",
    BLUE        => "\x0302",
    GREEN       => "\x0303",
    RED         => "\x0304",
    BROWN       => "\x0305",
    PURPLE      => "\x0306",
    ORANGE      => "\x0307",
    YELLOW      => "\x0308",
    TEAL        => "\x0310",
    PINK        => "\x0313",
    GREY        => "\x0314",
    GRAY        => "\x0314",

    LIGHT_BLUE  => "\x0312",
    LIGHT_CYAN  => "\x0311",
    LIGHT_GREEN => "\x0309",
    LIGHT_GRAY  => "\x0315",
    LIGHT_GREY  => "\x0315",
  );
  my $selected = $colors{$format};

  return $selected . $str . $colors{NORMAL} if $str;

  return $selected || $colors{NORMAL};
};

## Time/date ops:

sub timestr_to_secs {
  ## turn something like 2h3m30s into seconds
  my $timestr = shift || return;
  my($hrs,$mins,$secs,$total);
  ## FIXME add days ?
  if ($timestr =~ m/(\d+)h/)
    { $hrs = $1; }
  if ($timestr =~ m/(\d+)m/)
    { $mins = $1; }
  if ($timestr =~ m/(\d+)s/)
    { $secs = $1; }
  $total = $secs;
  $total += (int $mins * 60) if $mins;
  $total += (int $hrs * 3600) if $hrs;
  return int($total)
}

sub secs_to_timestr {
  ## reverse of timestr_to_secs, sort of
  ## turn seconds into a string like '0 days, 00:00:00'
  my $diff = shift || return;
  my $days   = int $diff / 86400;
  my $sec    = $diff % 86400;
  my $hours  = int $sec / 3600;  $sec   %= 3600;
  my $mins   = int $sec / 60;    $sec   %= 60;
  return sprintf("%d days, %2.2d:%2.2d:%2.2d",
    $days, $hours, $mins, $sec
  );
}


## (b)crypt frontends:

sub passwdcmp {
  my $pwd   = shift || return;
  my $crypt = shift || return;

  ## realistically this should be a regex ..
  ## we don't handle regular old blowfish
  if ( index($crypt, '$2a$') == 0 ) ## bcrypted
  {
    return 0 unless $crypt eq
      Crypt::Eksblowfish::Bcrypt::bcrypt($pwd, $crypt);
  }
  else  ## some crypt() method, hopefully we have it!
  {
    return 0 unless $crypt eq crypt($pwd, $crypt);
  }

  return $crypt
}

sub mkpasswd {
  my ($pwd, $type, $cost) = @_;

  $type = 'bcrypt' unless $type;

  # generate a new passwd based on $type

  # a default (randomized) salt ..
  # we can use it for MD5 or build on it for SHA
  my @p = ('a' .. 'z', 'A' .. 'Z', 0 .. 9, '_');
  my $salt = join '', map { $p[rand@p] } 1 .. 8;

  given ($type)
  {
    when (/sha-?512/i) {  ## SHA-512: glibc-2.7+
        ## unfortunately mostly only glibc has support in crypt()
        ## SHA has variable length salts (up to 16)
        ## varied salt lengths can (maybe) slow down attacks
        ## (so says Drepper, anyway)
        $salt .= $p[rand@p] for 1 .. rand 8;
        $salt = '$6$'.$salt.'$';
    }

    when (/sha-?256/i) {  ## SHA-256: glibc-2.7+
        $salt .= $p[rand@p] for 1 .. rand 8;
        $salt = '$5$'.$salt.'$';
    }

    when (/^bcrypt$/i) {  ## Bcrypt via Crypt::Eksblowfish
        ## blowfish w/ cost factor
        ## cost value is configurable, but 08 is a good choice.
        ## has to be a two digit power of 2. pad with 0 as needed
        $cost //= '08';
        ## try to pad with 0 if user is an idiot
        ## not documented because you shouldn't be an idiot:
        $cost = '0'.$cost if length $cost == 1;
        ## bcrypt expects 16 octets of salt:
        $salt = join '', map { chr(int(rand(256))) } 1 .. 16;
        ## ...base64-encoded via bcrypt's en_base64:
        $salt = Crypt::Eksblowfish::Bcrypt::en_base64( $salt );
        ## actual settings string to feed bcrypt ($2a$COST$SALT)
        $salt = join '', '$2a$', $cost, '$', $salt;
        return Crypt::Eksblowfish::Bcrypt::bcrypt($pwd, $salt)
    } 

    default {  ## defaults to MD5 -- portable, fast, but weak
        $salt = '$1$'.$salt.'$';
    }

  }

  return crypt($pwd, $salt)
}


1;

=pod

=head1 NAME

Cobalt::Utils

=head1 DESCRIPTION

Cobalt::Utils provides a set of simple utility functions for the 
B<cobalt2> core and plugins.

Plugin authors may wish to make use of these; simply importing the 
C<:ALL> set from Cobalt::Utils will give you access to the entirety of
this utility module, including useful string formatting tools, safe 
password hashing functions, etc. See L</USAGE>, below.

=head1 USAGE

Import nothing:

  use Cobalt::Utils;
  my $hash = Cobalt::Utils::mkpasswd('things');

Import some things:

  use Cobalt::Utils qw/ mkpasswd passwdcmp /;
  my $hash = mkpasswd('things');

Import everything:

  use Cobalt::Utils qw/ :ALL /;
  my $hash = mkpasswd('things', 'md5');
  my $secs = timestr_to_secs('3h30m');


=head1 FUNCTIONS


=head2 Date and time

=head3 timestr_to_secs

Convert a string such as "2h10m" into seconds.

  my $delay_s = timestr_to_secs('1h33m10s');

=head3 secs_to_timestr

Convert a TS delta into a string.

Useful for uptime reporting, for example:

  my $delta = time() - $your_start_TS;
  my $uptime_str = secs_to_timestr($delta);


=head2 String formatting

=head3 color

Add mIRC formatting and color codes to a string.

Valid formatting codes:

  NORMAL BOLD UNDERLINE REVERSE ITALIC

Valid color codes:

  WHITE BLACK BLUE GREEN RED BROWN PURPLE ORANGE YELLOW TEAL PINK
  LIGHT_CYAN LIGHT_BLUE LIGHT_GRAY LIGHT_GREEN

Format/color type can be passed in upper or lower case.

If passed just a color or format name, returns the control code.

If passed nothing at all, returns the 'NORMAL' code.

  my $str = color('bold') . "bold text" . color() . "normal text";

If passed a color or format name and a string, returns the formatted
string, terminated by NORMAL:

  my $formatted = color('red', "red text") . "normal text";


=head3 rplprintf

String formatting with replacement of arbitrary variables.

  rplprintf( $string, $hash );

The first argument to C<rplprintf> should be the template string. 
It may contain variables in the form of C<%var> to be replaced.

The second argument is the hashref mapping C<%var> variables to 
strings.

For example:

  $string = "Access denied for %user (%host%)";
  $response = rplprintf( $string,
    { 
      user => "Joe",
      host => "joe!joe@example.org",
    } 
  );  ## 'Access denied for Joe (joe!joe@example.org)'

Intended for formatting langset RPLs before sending.

Variable names can be terminated with a space or % -- both are demonstrated 
in the example above.

=head2 Password handling

=head3 mkpasswd

Simple interface for creating hashed passwords:

  ## create a bcrypted password (work cost 08)
  ## bcrypt is blowfish with a work cost factor.
  ## if hashes are stolen, they'll be slow to break
  ## see http://codahale.com/how-to-safely-store-a-password/
  my $hashed = mkpasswd($password);

  ## you can specify method options . . .
  ## here's bcrypt with a lower work cost factor.
  ## (must be a two-digit power of 2, possibly padded with 0)
  my $hashed = mkpasswd($password, 'bcrypt', '06');

  ## Available methods:
  ##  bcrypt (preferred)
  ##  SHA-256 or -512 (glibc2.7+ only)
  ##  MD5 (fast, portable, weak)
  my $sha_passwd = mkpasswd($password, 'sha512');
  ## same as:
  my $sha_passwd = mkpasswd($password, 'SHA-512');


=head3 passwdcmp

  return passwdcmp($password, $hashed);

Returns the hash if the cleartext password is a match.
Otherwise, returns 0.

=head1 AUTHOR

Jon Portnoy (avenj)

L<http://www.cobaltirc.org>

=cut
