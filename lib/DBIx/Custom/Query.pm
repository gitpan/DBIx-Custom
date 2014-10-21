package DBIx::Custom::Query;

use strict;
use warnings;

use base 'Object::Simple';

__PACKAGE__->attr([qw/columns filter sql sth/]);

# DEPRECATED!
__PACKAGE__->attr('default_filter');

1;

=head1 NAME

DBIx::Custom::Query - Query

=head1 SYNOPSIS
    
    my $query = DBIx::Custom::Query->new;
    
=head1 ATTRIBUTES

=head2 C<columns>

    my $columns = $query->columns;
    $query      = $query->columns(['auhtor', 'title']);

Column names.

=head2 C<filter>

    my $filter = $query->filter;
    $query     = $query->filter({author => 'to_something',
                                 title  => 'to_something'});

Filters when parameter binding is executed.
This overwrites C<default_filter>.

=head2 C<sql>

    my $sql = $query->sql;
    $query  = $query->sql('select * from books where author = ?;');

SQL statement.

=head2 C<sth>

    my $sth = $query->sth;
    $query  = $query->sth($sth);

Statement handle of L<DBI>

=head1 METHODS

L<DBIx::Custom::Query> inherits all methods from L<Object::Simple>.

=cut
