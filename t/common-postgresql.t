use strict;
use warnings;

use FindBin;
$ENV{DBIX_CUSTOM_TEST_RUN} = 1
  if -f "$FindBin::Bin/run/common-postgresql.run";
$ENV{DBIX_CUSTOM_SKIP_MESSAGE} = 'postgresql private test';

use DBIx::Custom;
{
    package DBIx::Custom;
    no warnings 'redefine';

    my $date_typename = 'Date';
    my $datetime_typename = 'Timestamp';

    sub date_typename { lc $date_typename }
    sub datetime_typename { 'timestamp without time zone' }

    my $date_datatype = 91;
    my $datetime_datatype = 11;

    sub date_datatype { lc $date_datatype }
    sub datetime_datatype { lc $datetime_datatype }
    
    has datetime_suffix => '';

    has dsn => "dbi:Pg:dbname=dbix_custom";
    has user  => 'dbix_custom';
    has password => 'dbix_custom';
    has exclude_table => sub {

        return qr/^(
            pg_|column_|role_|view_|sql_
            |applicable_roles
            |check_constraints
            |columns
            |constraint_column_usage
            |constraint_table_usage
            |data_type_privileges
            |domain_constraints
            |domain_udt_usage
            |domains
            |element_types
            |enabled_roles
            |information_schema
            |information_schema_catalog_name
            |key_column_usage
            |parameters
            |referential_constraints
            |routine_privileges
            |routines
            |schemata
            |table_constraints
            |table_privileges
            |tables
            |triggered_update_columns
            |triggers
            |usage_privileges
            |views
        )/x
    };
    
    sub create_table1 { 'create table table1 (key1 varchar(255), key2 varchar(255));' }
    sub create_table1_2 {'create table table1 (key1 varchar(255), key2 varchar(255), '
     . 'key3 varchar(255), key4 varchar(255), key5 varchar(255));' }
    sub create_table1_type { "create table table1 (key1 $date_typename, key2 $datetime_typename);" }
    sub create_table1_highperformance { "create table table1 (ab varchar(255), bc varchar(255), "
      . "ik varchar(255), hi varchar(255), ui varchar(255), pq varchar(255), dc varchar(255));" }
    sub create_table2 { 'create table table2 (key1 varchar(255), key3 varchar(255));' }
    sub create_table2_2 { "create table table2 (key1 varchar(255), key2 varchar(255), key3 varchar(255))" }
    sub create_table3 { "create table table3 (key1 varchar(255), key2 varchar(255), key3 varchar(255))" }
    sub create_table_reserved { 'create table "table" ("select" varchar(255), "update" varchar(255))' }
}

require "$FindBin::Bin/common.t";
