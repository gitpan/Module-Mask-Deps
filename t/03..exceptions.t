use strict;
use warnings;

use Cwd qw( chdir cwd );
use File::Temp qw( tempdir );

use Test::More tests => 4;

require_ok('Module::Mask::Deps');

my $root = cwd;
my $dir = tempdir( CLEANUP => 1);

chdir $dir;
eval { new Module::Mask::Deps };
like(
    $@, qr(Couldn't find dependencies),
    'new fails with no Build.PL or Makefile.PL'
);

# Create empty Makefile.PL
open my $makefile, '>', 'Makefile.PL' or die "Can't write Makefile.PL";
close $makefile;

{
    # Make running Makefile.PL fail

    # can't think how else to make this fail..
    local $^X = 'invalid command';

    # and suppress the warning
    local $SIG{__WARN__} = sub {};

    eval { new Module::Mask::Deps };
    like(
        $@, qr(Couldn't find dependencies),
        'new fails when $^X can\'t be run'
    );
}

{
    eval { new Module::Mask::Deps };
    like(
        $@, qr(Couldn't find dependencies),
        'new fails with bad Makefile.PL'
    );

}

__END__

vim: ft=perl ts=8 sts=4 sw=4 sr et
