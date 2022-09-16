#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

use Object::Pad ':experimental(mop)';

{
   package ARole {
      BEGIN {
         Object::Pad->import_into( "ARole" );

         my $rolemeta = Object::Pad::MOP::Class->begin_role( "ARole" );

         $rolemeta->add_field( '$field',
            param => "role_field",
            reader => "get_role_field",
         );

         $rolemeta->add_required_method( 'some_method' );
      }
   }
}

{
   class AClass :does(ARole) {
      method some_method {}
   }

   my $obj = AClass->new( role_field => "the field value" );
   is( $obj->get_role_field, "the field value", 'instance field accessible via role' );
}

{
   ok( !eval "class BClass :does(ARole) { }", 'BClass does not compile' );
   like( $@, qr/^Class BClass does not provide a required method named 'some_method' at /,
      'message from failure to compile BClass' );
}

done_testing;
