package MyModel4::TABLE2;

use base 'MyModel4';

sub insert { shift->SUPER::insert($_[0]) }
sub list { shift->select }

1;
