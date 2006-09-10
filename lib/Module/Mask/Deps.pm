package Module::Mask::Deps;

use strict;
use warnings;

our $VERSION = '0.04';

=head1 NAME

Module::Mask::Deps - Mask modules not listed as dependencies

=head1 SYNOPSIS

Cause your test suite to blow up if you require a module not listed as a requirement in Build.PL:

    perl Build.PL
    PERL_HARNESS_SWITCHES=-MModule::Mask::Deps ./Build test

Or use directly in your testing code:

    use Module::Mask::Deps;

    BEGIN {
        # die if an unlisted module is used
        use_ok('My::Module');
    }

    # turn off masking (at compile time)
    no Module::Mask::Deps;

    # .. or at run-time
    unimport Module::Mask::Deps;

Or use lexically:

    require Module::Mask::Deps;

    {
        my $mask = new Module::Mask::Deps;

        # Non-dependencies masked until end-of-scope.

        # ... 
    }

    require Arbitrary::Module;

=head1 DESCRIPTION

This module aims to help module developers keep track of their dependencies by
only allowing modules to be loaded if they are in core or are listed as
dependencies.

It uses L<Module::CoreList> and either L<Module::Build> or
L<ExtUtils::MakeMaker> to build its list of declared dependant modules.

Under Module::Build, the core module collection for the declared minimum perl
version is used instead of the current core list.

=cut

use Module::CoreList;

use Module::Mask;

use File::Spec::Functions qw(
    file_name_is_absolute
    updir
    splitdir
    abs2rel
);

our @ISA = qw( Module::Mask::Inverted );

=head1 METHODS

=head2 import

    use Module::Mask::Deps;

    import Module::Mask::Deps;

Causes a L<Module::Mask::Deps> object to be created as
$Module::Mask::Deps::Mask. This means that when called with C<use> the mask
object is is in scope at compile time and therefore should affect all subsequent
C<use> and C<require> statements in the program.

=cut

our $Mask;

sub import {
    my $class = shift;

    if ($Mask) {
        $Mask->set_mask;
    }
    else {
        $Mask = new $class;
    }
}

=head2 unimport

    unimport Module::Mask::Deps

    no Module::Mask::Deps;

Stops the mask from working until import is called again. See clear_mask in L<Module::Mask>

Note that C<no Module::Mask::Deps> occurs at compile time and is not lexical int
he same way as C<no strict> and <no warnings> are.

=cut

sub unimport {
    my $class = shift;

    $Mask->clear_mask if $Mask;
}

=head2 new

    $obj = $class->new()

Returns a new Module::Mask::Deps object. See L<Module::Mask> for details about
how modules are masked.

=cut

sub new {
    my $class = shift;

    my @deps = $class->get_deps;

    return $class->SUPER::new(@deps);
}

=head2 set_mask

    $obj = $obj->set_mask()

Overloaded from Module::Mask to place the mask object after any relative paths
at the beginning of @INC.

Typically, in a testing environment, local paths are unshifted into @INC by
blib.pm, lib.pm or command-line switches. We don't want the mask to affect those
paths.

Also, relative paths passed to require will not be masked.

    # Will check @INC but won't be masked
    require 't/my_script.pl';

    # Won't even check @INC
    require './t/my_script.pl';

=cut

sub set_mask {
    my $self = shift;

    $self->SUPER::set_mask();
    # now the mask should be at the start of @INC

    # This is less code, but it's not as clear.
    # Might even be less efficient.
    # for (my $i = 1; $self->_rel_path($INC[$i]); $i++) {
        # unshift @INC, splice @INC, $i, 1;
    # }

    # count how many relative paths follow the mask object
    my $count = 0;
    for my $entry (@INC[1 .. $#INC]) {
        if ($self->_rel_path($entry)) {
            $count++;
        }
        else {
            last;
        }
    }

    # move relative entries in front of the mask object
    unshift @INC, splice @INC, 1, $count;

    return $self;
}

sub _rel_path {
    my ($self, $entry) = @_;
    
    return !file_name_is_absolute($entry)
        || (splitdir(abs2rel($entry)))[0] ne updir
}

# prevent sub-dependencies from being masked
sub Module::Mask::Deps::INC {
    my ($self, $module) = @_;

    if ($self->is_masked($module)) {
        my ($call_pack, $call_file) = caller;

        if ($self->_is_listed($call_pack)) {
            # we've explicitly whitelisted the calling package,
            # don't mask its dependencies

            # also add this module to the whitelist
            $self->mask_modules($module);

            return;
        }
        elsif (-f $module) {
            # $module must be a local, relative path.
            # Absolute paths don't check @INC
            # It will be loaded as long as . is in @INC
            return;
        }
        else {
            # Maybe we're being called from a package defined inside a module
            # file 
            my %inc_lookup = reverse %INC;

            # This won't work unless the module is loaded from the filesystem
            my $call_mod = $inc_lookup{$call_file};

            if ($call_mod and $self->_is_listed($call_mod)) {
                # Add the sub-package to the whitelist so we don't need to
                # re-check next time
                $self->mask_modules($call_pack, $module);

                return;
            }
        }
    }

    return $self->SUPER::INC($module);
}

=head2 get_deps

    @deps = $class->get_deps()

Returns current dependencies as defined in either Build.PL or Makefile.PL. This
is used internally by import and new, so there's no need to call it directly.

It returns all explicitly defined dependencies, plus all core dependencies.

=cut

# methods to try to get dependencies from
# subclasses may want to add to this list to get their methods to be called get
# get_deps
our @dep_methods = qw(
    _get_builder_deps
    _get_makefile_deps
);

sub get_deps {
    my $class = shift;

    for my $method (@dep_methods) {
        my @deps = eval { $class->$method };
        last if $@;
        return @deps if @deps;
    }

    die "$class: Couldn't find dependencies\n", $@ ? "$@\n" : '';
}

=head3 Module::Build

If Build.PL exists, Module::Build->current is used to obtain a Module::Build
object, and its C<requires> and C<build_requires> fields are used as
dependencies.

This means that the dependencies can only be picked up if Build.PL has already
been run.

If a particular perl version is specified as a dependency, then the list of core
modules for that version of perl is used. 

Note that modules in C<recommends> are not included.

=cut

# get dependencies from Module::Build
# return nothing if this isn't a Module::Build distro, die if something goes
# wrong.
sub _get_builder_deps {
    my $class = shift;

    return unless -f 'Build.PL';

    my $build = do {
        require Module::Build;

        # suppress warnings in current
        local $SIG{__WARN__} = sub {};

        current Module::Build;
    };

    # method names to call to get dependencies from a Module::Build object
    my @dep_fields = qw( requires build_requires );

    # copy and merge all deps.
    my %deps = map { %{$build->$_} } @dep_fields;
    
    # find target perl version, if present.
    my $perl_version = delete $deps{'perl'} || $];

    return $class->_merge_core($perl_version, keys %deps);
}

=head3 ExtUtils::MakeMaker

If Makefile.PL exists, dependencies are obtained by running C<perl Makefile.PL
PREREQ_PRINT=1>.

The current perl version ($]) is always used to determine core modules.

=cut

# get dependencies from ExtUtils::MakeMaker
sub _get_makefile_deps {
    my $class = shift;
    my @deps;

    # return on error, since we might have other _get_*_deps methods to try..
    return unless -f 'Makefile.PL';

    my @cmd = ($^X, 'Makefile.PL', 'PREREQ_PRINT=1');
    local $" = ' ';
    my $code = qx( @cmd );

    if ($code =~ /^ \$PREREQ_PM \s* = \s* {/x) {
        # Let's not eval arbitrary code...
        # We only need the names anyway
        @deps = $code =~ /^\s+'([\w:]+)/mg;
    }
    else {
        die "@cmd returned erroneous code\n";
    }

    return $class->_merge_core($], @deps);
}

# convenience function to return unique deps for a given perl version and
# dependency list
sub _merge_core {
    my ($class, $version, @deps) = @_;
    my @core = $class->_get_core($version);
    my %seen;

    return grep { !$seen{$_}++ } (@core, @deps);
}

# Find core modules for the given perl version
sub _get_core {
    my $class = shift;
    my $perl_version = shift;
    my @core;

    @core = $class->_core_for_version($perl_version);

    return @core if @core;

    # Nothing found,
    # Maybe $perl_version needs reformatting..

    my $clean = $class->_clean_version($perl_version);
    
    @core = $class->_core_for_version($clean);

    return @core if @core;

    # still nothing..

    die "$class: Couldn't find core modules for perl $perl_version\n";
}

# wrap %Module::CoreList::version
sub _core_for_version {
    my $class = shift;
    my $perl_version = shift;

    if (exists $Module::CoreList::version{$perl_version}) {
        return keys %{$Module::CoreList::version{$perl_version}};
    }
    else {
        return;
    }
}

# try to transform perl version numbers into the type used in Module::CoreList
sub _clean_version {
    my ($class, $version) = @_;

    my ($major, @minors) = split(/[._]/, $version);

    # we don't want trailing zeros
    pop @minors while @minors && $minors[-1] == 0;

    @minors = map { sprintf('%03d', $_) } @minors;

    if (@minors > 1 && $major == 5 && $minors[0] >= 3 && $minors[0] < 6) {
        # Between 5.3 and 5.6, the second minor version is 2 digits
        # 5.3.7 => 5.00307
        # 5.5.3 => 5.00503

        $minors[1] =~ s/^0//;
    }

    local $" = '';

    return @minors ? "$major.@minors" : $major;
}

1;

__END__

=head1 BUGS

Like Module::Mask, already loaded modules cannot be masked. This means that
dependencies of Module::Mask::Deps can never be masked.

Notably, Module::Mask, Module::Util and Module::CoreList fall into this
category.

To see a full list of modules for which this applies, run:

    perl -le 'require Module::Mask::Deps; print for keys %INC'

=head1 DIAGNOSTICS

All error messages are prefixes by the name of the calling class, e.g.

    Module::Mask::Deps: Couldn't find dependencies

The following fatal errors can occur:

=over

=item * Couldn't find dependencies

The class couldn't find dependencies for the current distribution.

If you are using Module::Build, ensure that you have run Build.PL and generated
a Build script.

If you are using ExtUtils::MakeMaker, ensure that the current directory contains
your Makefile.PL script.

Further information about the error might be provided on subsequent lines.

=item * Couldn't find core modules for perl $version

The given perl version couldn't be found in %Module::CoreList::version, you
might need to upgrade L<Module::CoreList>, or the perl version specified in
Build.PL might be invalid. Otherwise, please report it as a bug.

=back

=head1 SEE ALSO

L<Module::Mask>, L<Module::CoreList>

=head1 AUTHOR

Matt Lawrence E<lt>mattlaw@cpan.orgE<gt>

=cut

vim: ts=8 sts=4 sw=4 sr et

