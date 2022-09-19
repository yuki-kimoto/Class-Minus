#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

use Object::Pad;

role ARole {
   method one { return 1 }

   method own_cvname {
      return +(caller(0))[3];
   }
}

class AClass :does(ARole) {
  method new : common {
    my $self = $class->SUPER::new(@_);
    
    return $self;
  }
}

{
   my $obj = AClass->new;
   isa_ok( $obj, "AClass", '$obj' );

   is( $obj->one, 1, 'AClass has a ->one method' );
   is( $obj->own_cvname, "AClass::own_cvname", '->own_cvname sees correct subname' );
}

role BRole {
   method two { return 2 }
}

class BClass :does(ARole) :does(BRole) {
  method new : common {
    my $self = $class->SUPER::new(@_);
    
    return $self;
  }
}

{
   my $obj = BClass->new;

   is( $obj->one, 1, 'BClass has a ->one method' );
   is( $obj->two, 2, 'BClass has a ->two method' );
   is( $obj->own_cvname, "BClass::own_cvname", '->own_cvname sees correct subname' );
}

role CRole {
   method three;
}

class CClass :does(CRole) {
   method three { return 3 }
}

pass( 'CClass compiled OK' );

# Because we store embedding info in the pad of a method CV, we should check
# that recursion and hence CvDEPTH > 1 works fine
{
   role RecurseRole {
      method recurse {
         my ( $x ) = @_;
         return $x ? $self->recurse( $x - 1 ) + 1 : 0;
      }
   }

   class RecurseClass :does(RecurseRole) {
      method new : common {
        my $self = $class->SUPER::new(@_);
        
        return $self;
      }
  }

   is( RecurseClass->new->recurse( 5 ), 5, 'role methods can be reëntrant' );
}

role DRole :does(BRole) {
   method four { return 4 }
}

class DClass :does(DRole) {
  method new : common {
    my $self = $class->SUPER::new(@_);
    
    return $self;
  }
}

{
   my $obj = DClass->new;

   is( $obj->four, 4, 'DClass has DRole method' );
   is( $obj->two,  2, 'DClass inherited BRole method' );
}

role ERole :does(ARole) :does(BRole) {
}

class EClass :does(ERole) {
  method new : common {
    my $self = $class->SUPER::new(@_);
    
    return $self;
  }
}

{
   my $obj = EClass->new;

   is( $obj->one, 1, 'EClass has a ->one method' );
   is( $obj->two, 2, 'EClass has a ->two method' );
}

role FRole {
   method onetwothree :common { 123 }
}

class FClass :does(FRole) {
  method new : common {
    my $self = $class->SUPER::new(@_);
    
    return $self;
  }
}

{
   is( FClass->onetwothree, 123, 'FClass has a :common ->onetwothree method' );
}

# Perl #19676
#   https://github.com/Perl/perl5/issues/19676

role GRole {
   method a { pack "C", 65 }
}

class GClass :does(GRole) {
  method new : common {
    my $self = $class->SUPER::new(@_);
    
    return $self;
  }

}

{
   is( GClass->new->a, "A", 'GClass ->a method has constant' );
}

done_testing;
