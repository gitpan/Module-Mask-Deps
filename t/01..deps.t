use strict;
use warnings;

use Cwd qw( chdir cwd );
use File::Spec::Functions qw( catdir rel2abs );
use IPC::Open3;

use Test::More tests => 23;

use lib catdir qw( t lib );

BEGIN {
    use_ok('Module::Mask::Deps');
}

our @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

{
    local %INC = %INC;
    eval { require Foo };
    ok(!$@, 'relative lib not affected by mask');
}

# Turn off masking now
unimport Module::Mask::Deps;

{
    local %INC = %INC;
    eval { require Foo };
    ok(!$@, 'no Module::Mask::Deps') or diag $@;
}

{
    local $Module::Mask::Deps::Mask;

    eval { unimport Module::Mask::Deps };
    ok(!$@, "unimport with no object lives") or diag $@;
}

# Put abs path to local t/lib into @INC at run time
my $test_lib = rel2abs(catdir qw( t lib ));
unshift @INC, $test_lib;

{
    local %INC = %INC;
    import Module::Mask::Deps;

    eval { require Foo };
    ok(!$@, 'absolute form of relative path still ignored by mask') or diag $@;
}

my $root = cwd();
my ($dist_dir, @deps, %dep_lookup);

$dist_dir = catdir qw( t data Test-Dist1 );
chdir $dist_dir or die "Can't change to $dist_dir";

{
    local @INC = (catdir('lib'), @INC);
    local %INC = %INC;
    local $Module::Mask::Deps::Mask;

    eval { import Module::Mask::Deps };
    like(
        $@, qr(Couldn't find dependencies),
        "Can't find dependencies before running Build.PL"
    );
}

{
    # make sure we don't get a missing prerequisite warning
    local $ENV{'PERL5LIB'} = $test_lib;

    my @deps = eval { Module::Mask::Deps->_get_makefile_deps() };

    ok($@, '_get_makefile_deps on invalid Makefile.PL dies');

    # clean up the generated makefile and Build script
    eval {
        unlink 'Makefile';
        do_realclean();
    };
    ok(!$@, 'cleaning up') or diag $@;
}

{
    my @errors;
    open3(*PERL_IN, *PERL_OUT, *PERL_ERR, $^X, '-I', $test_lib, 'Build.PL');
    close PERL_IN;
    close PERL_OUT;
    @errors = <PERL_ERR>;
    close PERL_ERR;

    ok(!@errors, 'No errors running Build.PL') or diag @errors;
}

@deps = Module::Mask::Deps->get_deps();
ok(@deps, "Got deps from $dist_dir");

%dep_lookup = map { $_ => 1 } @deps;

ok($dep_lookup{'Foo'}, 'picked up known dependency');

# English has been core since perl 5
ok($dep_lookup{'English'}, 'picked up known core module');

{
    # simulate -I lib 
    local @INC = (catdir('lib'), @INC);

    # don't remember what we load
    local %INC = %INC;
    local $Module::Mask::Deps::Mask;

    # we should allow relative paths to be loaded
    eval { require 'test.pl'};
    ok(!$@, 'test.pl loaded OK') or diag $@;

    eval { import Module::Mask::Deps };
    ok(!$@, 'import Module::Mask::Deps on a valid distribution works');

    eval { require Test::Dist1 };
    ok(!$@, 'valid distribution loads OK') or diag $@;

    # Module::Mask should be installed and masked
    # this will need to be changed if Module::Mask ever becomes core!
    delete $INC{'Module/Mask.pm'};
    eval { require Module::Mask };
    ok($@, 'Module::Mask is masked');

    eval { do_realclean() };
    ok(!$@, 'cleaning up') or diag $@;
}

$dist_dir = catdir qw( t data Test-Dist2 );
$dist_dir = rel2abs($dist_dir, $root);

chdir $dist_dir or die "Can't change to $dist_dir";

@deps = Module::Mask::Deps->get_deps();

ok(@deps, "Got deps from $dist_dir");

%dep_lookup = map { $_ => 1 } @deps;
ok($dep_lookup{'Foo'}, "picked up known dependency");

# English has been core since perl 5
ok($dep_lookup{'English'}, 'picked up known core module');

{
    local @INC = (catdir('lib'), @INC);
    local %INC = %INC;
    local $Module::Mask::Deps::Mask;

    eval { import Module::Mask::Deps };
    ok(!$@, 'import Module::Mask::Deps on a valid distribution works');

    eval { require Test::Dist2 };
    ok(!$@, 'valid distribution loads OK') or diag $@;
}

# Go back home
chdir $root;

ok(!@warnings, 'no warnings generated') or diag join("\n", @warnings);

sub do_realclean {
    # clean up
    local $SIG{__WARN__} = sub {}; # suppress warnings
    my $temp;
    open my $catch_print, '>', \$temp;
    my $old = select $catch_print;
    Module::Build->current->dispatch('realclean');
    select $old;
    close $catch_print;
}

__END__

vim: ft=perl ts=8 sts=4 sw=4 sr et
