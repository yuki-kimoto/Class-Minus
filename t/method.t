#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;
use Test::Refcount;

use Class::Plain;

class Point {
   field x;
   field y;
   
   method where { sprintf "(%d,%d)", $self->{x}, $self->{y} }
}

{
   my $p = Point->new(x => 10, y => 20 );
   is_oneref( $p, '$p field refcount 1 initially' );

   is( $p->where, "(10,20)", '$p->where' );
   is_oneref( $p, '$p field refcount 1 after method' );
}

# nested anon method (RT132321)
SKIP: {
   skip "This causes SEGV on perl 5.16 (RT132321)", 1 if $] lt "5.018";
   class RT132321 {
      field _genvalue;

     method new : common {
       my $self = $class->SUPER::new(@_);

       $self->{_genvalue} //= method { 123 };
       
       return $self;
     }

      method value { $self->{_genvalue}->($self) }
   }

   my $obj = RT132321->new;
   is( $obj->value, 123, '$obj->value from generated anon method' );
}

{
  class MyClassSignature {
    use experimental 'signatures';
    
    method foo ($foo) {
      my $ppp = method {
        1;
      };
    
      return $foo;
    }
  }

  my $foo = MyClassSignature->new;

  is($foo->foo(4), 4);
}

{
  class ClassAnonMethod {
     field data;

     method new : common {
       my $self = $class->SUPER::new(@_);
       
       return $self;
     }

     my $priv = method {
        "data<$self->{data}>";
     };

     method m { return $self->$priv }
  }

  {
     my $obj = ClassAnonMethod->new( data => "value" );
     is( $obj->m, "data<value>", 'method can invoke captured method ref' );
  }
}

{
  class ClassException {
     field x;
     method clear { $self->{x} = 0 }
  }

  {
     ok( !eval { ClassException->clear },
        'method on non-instance fails' );
     like( $@, qr/^Cannot invoke method on a non-instance /,
        'message from method on non-instance' );
  }
}

done_testing;
