#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

use Class::Plain;

class Counter {
   field count;
   
   method new : common {
     my $self = $class->SUPER::new(@_);
     
     return $self;
   }

   method inc { $self->{count}++ };
   method make_incrsub {
      return sub { $self->{count}++ };
   }

   method count { $self->{count} }
}

{
   my $counter = Counter->new;
   my $inc = $counter->make_incrsub;

   $inc->();
   $inc->();

   is( $counter->count, 2, '->count after invoking incrsub' );
}

# RT132249
{
   class Widget {
      field _menu;
      method popup_menu {
         my $on_activate = sub { undef $self->{_menu} };
      }
      method on_mouse {
      }
   }

   # If we got to here without crashing then the test passed
   pass( 'RT132249 did not cause a crash' );
}

done_testing;
