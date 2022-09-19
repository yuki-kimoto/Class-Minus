#!/usr/bin/perl

use v5.14;
use warnings;

use Test::More;

use Class::Plain;

{
   role ARole { method m {} }

   my $warnings;
   $SIG{__WARN__} = sub { $warnings .= join "", @_ };

   ok( !eval <<'EOPERL',
      class AClass does ARole { method m {} }
EOPERL
      'class with clashing method name fails' );
   like( $@, qr/^Method 'm' clashes with the one provided by role ARole /,
      'message from failure of clashing method' );

   ok( !eval { ( bless {}, "ARole" )->m() },
      'direct invoke on role method fails' );
   like( $@, qr/^Cannot invoke a role method directly /,
      'message from failure to directly invoke role method' );
}

{
   role BRole { method bmeth; }

   ok( !eval <<'EOPERL',
      class BClass does BRole { }
EOPERL
      'class with missing required method fails' );
   like( $@, qr/^Class BClass does not provide a required method named 'bmeth' /,
      'message from failure of missing method' );
}

done_testing;
