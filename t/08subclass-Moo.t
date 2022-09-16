#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

BEGIN {
   plan skip_all => "Moo is not available"
      unless eval { require Moo };
}

use Object::Pad;

my $moocount;
package Base::Class {
   use Moo;
   sub BUILD {
      my ( $self, $args ) = @_;
      Test::More::is_deeply( $args, { arg => "value" }, '@_ to Base::Class::BUILD' );
      $moocount++;
   }
}

my $opcount;
class Derived::Class :isa(Base::Class) {
   field $field;
   BUILD {
      my ( $args ) = @_;
      Test::More::is_deeply( $args, { arg => "value" }, '@_ to Derived::Class BUILD' );
      $field = 345;
      $opcount++;
   }
   method field { $field }
}

{
   my $obj = Derived::Class->new( arg => "value" );
   is( $obj->field, 345, 'field value' );
}

# Ensure the BUILD blocks don't collide with Moo's BUILD methods
is( $moocount, 1, 'Moo BUILD method invoked only once' );
is( $opcount, 1, 'Object::Pad BUILD block invoked only once' );

done_testing;
