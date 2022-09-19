#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

use Object::Pad;

class Base::Class {
   field $data;
   method data { $data }

   ADJUST {
      $data = "base data"
   }
}

class Derived::Class :isa(Base::Class) {
   field $data;
   method data { $data }

   ADJUST {
      $data = "derived data";
   }
}

{
   my $c = Derived::Class->new;
   is( $c->data, "derived data",
      'subclass wins methods' );
   is( $c->Base::Class::data, "base data",
      'base class still accessible' );
}

done_testing;
