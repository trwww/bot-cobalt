use Test::More tests => 11;

use Fcntl qw/ :flock /;
use File::Spec;
use File::Temp qw/ tempfile tempdir /;

BEGIN { use_ok( 'Cobalt::DB' ); use_ok( 'Cobalt::Serializer'); }

my $workdir = File::Spec->tmpdir;
my $tempdir = tempdir( CLEANUP => 1, DIR => $workdir );

my ($fh, $path) = _newtemp();
my $db;

ok( $db = Cobalt::DB->new( File => $path ), 'Cobalt::DB new()' );
can_ok( $db, 'dbdump' );

ok( $db->dbopen, 'Temp database open' );
ok( $db->put('testkey', { Deep => { Hash => 1 } }), 'Database put()');

$db->dbclose;

my $serializer;
ok( 
  $serializer = Cobalt::Serializer->new('YAML'),
  'Create Cobalt::Serializer'
);

ok( $db->dbopen, 'Temp database reopen' );

my $yaml;
ok(
  $yaml = $db->dbdump,
  'Dump DB to YAML'
);

$db->dbclose;

my $ref;
ok( $ref = $serializer->thaw($yaml), 'YAML thaw' );
ok( $ref->{testkey}->{Deep}->{Hash}, 'dbdump deserialized match' );
undef $ref;

sub _newtemp {
    my ($fh, $filename) = tempfile( 'tmpdbXXXXX', 
      DIR => $tempdir, UNLINK => 1 
    );
    flock $fh, LOCK_UN;
    return($fh, $filename)
}
