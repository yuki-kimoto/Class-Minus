#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

use Class::Plain;

use lib "t/lib";
BEGIN { require "91rt141483Role.pm" }

class C :does(R) {
  method new : common {
    my $self = $class->SUPER::new(@_);
    
    return $self;
  }
  
}

is( C->new->name, "Gantenbein", 'Value preserved from role-scoped lexical' );

done_testing;
