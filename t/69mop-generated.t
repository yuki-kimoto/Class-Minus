#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

use Object::Pad::MOP::Class ':experimental(mop)';

# An attempt to programmatically generate everything
{
   my $classmeta = Object::Pad::MOP::Class->create_class( "Point" );

   my $xfieldmeta = $classmeta->add_field( '$x', param => 1, reader => 'x' );
   my $yfieldmeta = $classmeta->add_field( '$y', param => 1, reader => 'y' );

   $classmeta->add_method( describe => sub {
      my $self = shift;
      return sprintf "Point(%d, %d)",
         $xfieldmeta->value($self), $yfieldmeta->value($self);
   } );

   $classmeta->seal;
}

{
   my $point = Point->new(x => 10, y => 20 );
   is( $point->describe, "Point(10, 20)",
      '$point->describe' );
   is( $point->x, 10, '$point->x' );
}

done_testing;
