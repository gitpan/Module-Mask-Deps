package Foo;

=head1 NAME

Foo - Fake dependency to be listed in test distributions for Module::Mask::Deps

=cut

# a sub-dependency to throw a potential spanner in the works:
use Bar;

our $VERSION = '1.00';

__END__
