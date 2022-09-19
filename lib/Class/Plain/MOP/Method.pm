#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2020 -- leonerd@leonerd.org.uk

package Class::Plain::MOP::Method 0.68;

use v5.14;
use warnings;

# This is an XS-implemented object type provided by Class::Plain itself
require Class::Plain;

=head1 NAME

C<Class::Plain::MOP::Method> - meta-object representation of a method of a C<Class::Plain> class

=head1 DESCRIPTION

Instances of this class represent a method of a class implemented by
L<Class::Plain>. Accessors provide information about the method.

This API should be considered B<experimental>, and will emit warnings to that
effect. They can be silenced with

   use Class::Plain qw( :experimental(mop) );

=cut

=head1 METHODS

=head2 name

   $name = $metamethod->name

Returns the name of the method, as a plain string.

=head2 class

Returns the L<Class::Plain::MOP::Class> instance representing the class of
which this method is a member.

=head2 is_common

   $bool = $metamethod->is_common

I<Since version 0.62.>

Returns true if the method is a class-common method, or false for a regular
instance method.

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
