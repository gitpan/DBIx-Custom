# Change quote for tests
use DBIx::Custom;
{
  package DBIx::Custom;
  no warnings 'redefine';
  sub quote { '""' }
}

use FindBin;

require "$FindBin::Bin/sqlite.t";
