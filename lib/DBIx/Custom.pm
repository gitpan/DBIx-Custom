package DBIx::Custom;

use strict;
use warnings;

use base 'Object::Simple';

use Carp 'croak';
use DBI;
use DBIx::Custom::Result;
use DBIx::Custom::SQLTemplate;
use DBIx::Custom::Query;

__PACKAGE__->attr('dbh');

__PACKAGE__->class_attr(_query_caches     => sub { {} });
__PACKAGE__->class_attr(_query_cache_keys => sub { [] });

__PACKAGE__->class_attr('query_cache_max', default => 50,
                                           inherit => 'scalar_copy');

__PACKAGE__->attr([qw/user password data_source/]);
__PACKAGE__->attr([qw/database host port/]);
__PACKAGE__->attr([qw/default_query_filter default_fetch_filter options/]);

__PACKAGE__->dual_attr([qw/ filters formats/],
                       default => sub { {} }, inherit => 'hash_copy');

__PACKAGE__->attr(result_class => 'DBIx::Custom::Result');
__PACKAGE__->attr(sql_tmpl => sub { DBIx::Custom::SQLTemplate->new });

sub resist_filter {
    my $invocant = shift;
    
    # Add filter
    my $filters = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $invocant->filters({%{$invocant->filters}, %$filters});
    
    return $invocant;
}

sub resist_format{
    my $invocant = shift;
    
    # Add format
    my $formats = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $invocant->formats({%{$invocant->formats}, %$formats});

    return $invocant;
}

sub _auto_commit {
    my $self = shift;
    
    # Not connected
    croak("Not yet connect to database") unless $self->dbh;
    
    if (@_) {
        
        # Set AutoCommit
        $self->dbh->{AutoCommit} = $_[0];
        
        return $self;
    }
    return $self->dbh->{AutoCommit};
}

sub connect {
    my $self = shift;
    
    # Information
    my $data_source = $self->data_source;
    my $user        = $self->user;
    my $password    = $self->password;
    my $options     = $self->options;
    
    # Connect
    my $dbh = eval{DBI->connect(
        $data_source,
        $user,
        $password,
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1,
            %{$options || {} }
        }
    )};
    
    # Connect error
    croak $@ if $@;
    
    # Database handle
    $self->dbh($dbh);
    
    return $self;
}

sub DESTROY {
    my $self = shift;
    
    # Disconnect
    $self->disconnect if $self->connected;
}

sub connected { ref shift->{dbh} eq 'DBI::db' }

sub disconnect {
    my $self = shift;
    
    if ($self->connected) {
        
        # Disconnect
        $self->dbh->disconnect;
        delete $self->{dbh};
    }
    
    return $self;
}

sub reconnect {
    my $self = shift;
    
    # Reconnect
    $self->disconnect if $self->connected;
    $self->connect;
    
    return $self;
}

sub create_query {
    my ($self, $template) = @_;
    
    my $class = ref $self;
    
    if (ref $template eq 'ARRAY') {
        $template = $template->[1];
    }
    
    # Create query from SQL template
    my $sql_tmpl = $self->sql_tmpl;
    
    # Try to get cached query
    my $cached_query = $class->_query_caches->{"$template"};
    
    # Create query
    my $query;
    if ($cached_query) {
        $query = DBIx::Custom::Query->new(
            sql       => $cached_query->sql,
            columns => $cached_query->columns
        );
    }
    else {
        $query = eval{$sql_tmpl->create_query($template)};
        croak($@) if $@;
        
        $class->_add_query_cache("$template", $query);
    }
    
    # Connect if not
    $self->connect unless $self->connected;
    
    # Prepare statement handle
    my $sth = $self->dbh->prepare($query->{sql});
    
    # Set statement handle
    $query->sth($sth);
    
    return $query;
}

sub execute{
    my ($self, $query, $params, $args)  = @_;
    $params ||= {};
    
    # First argument is SQL template
    unless (ref $query eq 'DBIx::Custom::Query') {
        my $template;
        
        if (ref $query eq 'ARRAY') {
            $template = $query->[0];
        }
        else { $template = $query }
        
        $query = $self->create_query($template);
    }

    # Filter
    my $filter = $args->{filter} || $query->filter || {};

    # Create bind value
    my $bind_values = $self->_build_bind_values($query, $params, $filter);
    
    # Execute
    my $sth      = $query->sth;
    my $affected = eval{$sth->execute(@$bind_values)};
    
    # Execute error
    if (my $execute_error = $@) {
        require Data::Dumper;
        my $sql              = $query->{sql} || '';
        my $params_dump      = Data::Dumper->Dump([$params], ['*params']);
        
        croak("$execute_error" . 
              "<Your SQL>\n$sql\n" . 
              "<Your parameters>\n$params_dump");
    }
    
    # Return resultset if select statement is executed
    if ($sth->{NUM_OF_FIELDS}) {
        
        # Get result class
        my $result_class = $self->result_class;
        
        # Create result
        my $result = $result_class->new({
            sth             => $sth,
            default_filter  => $self->default_fetch_filter,
            filters         => $self->filters
        });
        return $result;
    }
    return $affected;
}

sub _build_bind_values {
    my ($self, $query, $params, $filter) = @_;
    
    # binding values
    my @bind_values;
    
    # Build bind values
    my $count = {};
    foreach my $column (@{$query->columns}) {
        
        # Value
        my $value = ref $params->{$column}
                  ? $params->{$column}->[$count->{$column} || 0]
                  : $params->{$column};
        
        # Filter
        $filter ||= {};
        
        # Filter name
        my $fname = $filter->{$column} || $self->default_query_filter || '';
        
        my $filters = $self->filters;
        push @bind_values, $filters->{$fname}
                         ? $filters->{$fname}->($value)
                         : $value;
        
        # Count up 
        $count->{$column}++;
    }
    
    return \@bind_values;
}

sub run_transaction {
    my ($self, $transaction) = @_;
    
    # Shorcut
    return unless $self;
    
    # Check auto commit
    croak("AutoCommit must be true before transaction start")
      unless $self->_auto_commit;
    
    # Auto commit off
    $self->_auto_commit(0);
    
    # Run transaction
    eval {$transaction->()};
    
    # Tranzaction error
    my $transaction_error = $@;
    
    # Tranzaction is failed.
    if ($transaction_error) {
        # Rollback
        eval{$self->dbh->rollback};
        
        # Rollback error
        my $rollback_error = $@;
        
        # Auto commit on
        $self->_auto_commit(1);
        
        if ($rollback_error) {
            # Rollback is failed
            croak("${transaction_error}Rollback is failed : $rollback_error");
        }
        else {
            # Rollback is success
            croak("${transaction_error}Rollback is success");
        }
    }
    # Tranzaction is success
    else {
        # Commit
        eval{$self->dbh->commit};
        my $commit_error = $@;
        
        # Auto commit on
        $self->_auto_commit(1);
        
        # Commit is failed
        croak($commit_error) if $commit_error;
    }
}

sub create_table {
    my ($self, $table, @column_definitions) = @_;
    
    # Create table
    my $sql = "create table $table (";
    
    # Column definitions
    foreach my $column_definition (@column_definitions) {
        $sql .= "$column_definition,";
    }
    $sql =~ s/,$//;
    
    # End
    $sql .= ");";
    
    # Connect
    $self->connect unless $self->connected;
    
    # Do query
    return $self->dbh->do($sql);
}

sub drop_table {
    my ($self, $table) = @_;
    
    # Drop table
    my $sql = "drop table $table;";

    # Connect
    $self->connect unless $self->connected;

    # Do query
    return $self->dbh->do($sql);
}

our %VALID_INSERT_ARGS = map { $_ => 1 } qw/append filter/;

sub insert {
    my ($self, $table, $insert_params, $args) = @_;
    
    # Table
    $table ||= '';
    
    # Insert params
    $insert_params ||= {};
    
    # Arguments
    $args ||= {};
    
    # Check arguments
    foreach my $name (keys %$args) {
        croak "\"$name\" is invalid name"
          unless $VALID_INSERT_ARGS{$name};
    }
    
    my $append_statement = $args->{append} || '';
    my $filter           = $args->{filter};
    
    # Insert keys
    my @insert_keys = keys %$insert_params;
    
    # Not exists insert keys
    croak("Key-value pairs for insert must be specified to 'insert' second argument")
      unless @insert_keys;
    
    # Templte for insert
    my $template = "insert into $table {insert " . join(' ', @insert_keys) . '}';
    $template .= " $append_statement" if $append_statement;
    
    # Execute query
    my $ret_val = $self->execute($template, $insert_params, {filter => $filter});
    
    return $ret_val;
}

our %VALID_UPDATE_ARGS
  = map { $_ => 1 } qw/where append filter allow_update_all/;

sub update {
    my ($self, $table, $params, $args) = @_;
    
    # Check arguments
    foreach my $name (keys %$args) {
        croak "\"$name\" is invalid name"
          unless $VALID_UPDATE_ARGS{$name};
    }
    
    # Arguments
    my $where_params     = $args->{where} || {};
    my $append_statement = $args->{append} || '';
    my $filter           = $args->{filter};
    my $allow_update_all = $args->{allow_update_all};
    
    # Update keys
    my @update_keys = keys %$params;
    
    # Not exists update kyes
    croak("Key-value pairs for update must be specified to 'update' second argument")
      unless @update_keys;
    
    # Where keys
    my @where_keys = keys %$where_params;
    
    # Not exists where keys
    croak("Key-value pairs for where clause must be specified to 'update' third argument")
      if !@where_keys && !$allow_update_all;
    
    # Update clause
    my $update_clause = '{update ' . join(' ', @update_keys) . '}';
    
    # Where clause
    my $where_clause = '';
    my $new_where = {};
    
    if (@where_keys) {
        $where_clause = 'where ';
        foreach my $where_key (@where_keys) {
            
            $where_clause .= "{= $where_key} and ";
        }
        $where_clause =~ s/ and $//;
    }
    
    # Template for update
    my $template = "update $table $update_clause $where_clause";
    $template .= " $append_statement" if $append_statement;
    
    # Rearrange parammeters
    foreach my $where_key (@where_keys) {
        
        if (exists $params->{$where_key}) {
            $params->{$where_key} = [$params->{$where_key}]
              unless ref $params->{$where_key} eq 'ARRAY';
            
            push @{$params->{$where_key}}, $where_params->{$where_key};
        }
        else {
            $params->{$where_key} = $where_params->{$where_key};
        }
    }
    
    # Execute query
    my $ret_val = $self->execute($template, $params, {filter => $filter});
    
    return $ret_val;
}

sub update_all {
    my ($self, $table, $update_params, $args) = @_;
    
    # Allow all update
    $args ||= {};
    $args->{allow_update_all} = 1;
    
    # Update all rows
    return $self->update($table, $update_params, $args);
}

our %VALID_DELETE_ARGS
  = map { $_ => 1 } qw/where append filter allow_delete_all/;

sub delete {
    my ($self, $table, $args) = @_;
    
    # Table
    $table            ||= '';

    # Check arguments
    foreach my $name (keys %$args) {
        croak "\"$name\" is invalid name"
          unless $VALID_DELETE_ARGS{$name};
    }
    
    # Arguments
    my $where_params     = $args->{where} || {};
    my $append_statement = $args->{append};
    my $filter    = $args->{filter};
    my $allow_delete_all = $args->{allow_delete_all};
    
    # Where keys
    my @where_keys = keys %$where_params;
    
    # Not exists where keys
    croak("Key-value pairs for where clause must be specified to 'delete' second argument")
      if !@where_keys && !$allow_delete_all;
    
    # Where clause
    my $where_clause = '';
    if (@where_keys) {
        $where_clause = 'where ';
        foreach my $where_key (@where_keys) {
            $where_clause .= "{= $where_key} and ";
        }
        $where_clause =~ s/ and $//;
    }
    
    # Template for delete
    my $template = "delete from $table $where_clause";
    $template .= " $append_statement" if $append_statement;
    
    # Execute query
    my $ret_val = $self->execute($template, $where_params, {filter => $filter});
    
    return $ret_val;
}

sub delete_all {
    my ($self, $table, $args) = @_;
    
    # Allow all delete
    $args ||= {};
    $args->{allow_delete_all} = 1;
    
    # Delete all rows
    return $self->delete($table, $args);
}

our %VALID_SELECT_ARGS
  = map { $_ => 1 } qw/columns where append filter/;

sub select {
    my ($self, $tables, $args) = @_;
    
    # Table
    $tables ||= '';
    $tables = [$tables] unless ref $tables;
    
    # Check arguments
    foreach my $name (keys %$args) {
        croak "\"$name\" is invalid name"
          unless $VALID_SELECT_ARGS{$name};
    }
    
    # Arguments
    my $columns          = $args->{columns} || [];
    my $where_params     = $args->{where} || {};
    my $append_statement = $args->{append} || '';
    my $filter    = $args->{filter};
    
    # SQL template for select statement
    my $template = 'select ';
    
    # Join column clause
    if (@$columns) {
        foreach my $column (@$columns) {
            $template .= "$column, ";
        }
        $template =~ s/, $/ /;
    }
    else {
        $template .= '* ';
    }
    
    # Join table
    $template .= 'from ';
    foreach my $table (@$tables) {
        $template .= "$table, ";
    }
    $template =~ s/, $/ /;
    
    # Where clause keys
    my @where_keys = keys %$where_params;
    
    # Join where clause
    if (@where_keys) {
        $template .= 'where ';
        foreach my $where_key (@where_keys) {
            $template .= "{= $where_key} and ";
        }
    }
    $template =~ s/ and $//;
    
    # Append something to last of statement
    if ($append_statement =~ s/^where //) {
        if (@where_keys) {
            $template .= " and $append_statement";
        }
        else {
            $template .= " where $append_statement";
        }
    }
    else {
        $template .= " $append_statement";
    }
    
    # Execute query
    my $result = $self->execute($template, $where_params, {filter => $filter});
    
    return $result;
}

sub _add_query_cache {
    my ($class, $template, $query) = @_;
    
    # Query information
    my $query_cache_keys = $class->_query_cache_keys;
    my $query_caches     = $class->_query_caches;
    
    # Already cached
    return $class if $query_caches->{$template};
    
    # Cache
    $query_caches->{$template} = $query;
    push @$query_cache_keys, $template;
    
    # Check cache overflow
    my $overflow = @$query_cache_keys - $class->query_cache_max;
    for (my $i = 0; $i < $overflow; $i++) {
        my $template = shift @$query_cache_keys;
        delete $query_caches->{$template};
    }
    
    return $class;
}

=head1 NAME

DBIx::Custom - DBI with hash bind and filtering system 

=head1 VERSION

Version 0.1301

=cut

our $VERSION = '0.1301';

=head1 STATE

This module is not stable. Method name and functionality will be change.

=head1 SYNOPSYS
    
    # New
    my $dbi = DBIx::Custom->new(data_source => "dbi:mysql:database=books"
                                user => 'ken', password => '!LFKD%$&');
    
    # Query
    $dbi->execute("select title from books");
    
    # Query with parameters
    $dbi->execute("select id from books where {= author} && {like title}",
                {author => 'ken', title => '%Perl%'});
    
    # Insert 
    $dbi->insert('books', {title => 'perl', author => 'Ken'});
    
    # Update 
    $dbi->update('books', {title => 'aaa', author => 'Ken'}, {where => {id => 5}});
    
    # Delete
    $dbi->delete('books', {where => {author => 'Ken'}});
    
    # Select
    my $result = $dbi->select('books');
    my $result = $dbi->select('books', {where => {author => 'taro'}}); 
    
    my $result = $dbi->select(
       'books', 
       {
           columns => [qw/author title/],
           where   => {author => 'Ken'}
        }
    );
    
    my $result = $dbi->select(
        'books',
        {
            columns => [qw/author title/],
            where   => {author => 'Ken'},
            append  => 'order by id limit 1'
        }
    );

=head1 ATTRIBUTES

=head2 user

Database user name
    
    $dbi  = $dbi->user('Ken');
    $user = $dbi->user;
    
=head2 password

Database password
    
    $dbi      = $dbi->password('lkj&le`@s');
    $password = $dbi->password;

=head2 data_source

Database data source
    
    $dbi         = $dbi->data_source("dbi:mysql:dbname=$database");
    $data_source = $dbi->data_source;
    
If you know data source more, See also L<DBI>.

=head2 database

Database name

    $dbi      = $dbi->database('books');
    $database = $dbi->database;

=head2 host

Host name

    $dbi  = $dbi->host('somehost.com');
    $host = $dbi->host;

You can also set IP address like '127.03.45.12'.

=head2 port

Port number

    $dbi  = $dbi->port(1198);
    $port = $dbi->port;

=head2 options

DBI options

    $dbi     = $dbi->options({PrintError => 0, RaiseError => 1});
    $options = $dbi->options;

=head2 sql_tmpl

SQLTemplate object

    $dbi      = $dbi->sql_tmpl(DBIx::Cutom::SQLTemplate->new);
    $sql_tmpl = $dbi->sql_tmpl;

See also L<DBIx::Custom::SQLTemplate>.

=head2 filters

Filters

    $dbi     = $dbi->filters({filter1 => sub { }, filter2 => sub {}});
    $filters = $dbi->filters;
    
This method is generally used to get a filter.

    $filter = $dbi->filters->{encode_utf8};

If you add filter, use resist_filter method.

=head2 formats

Formats

    $dbi     = $dbi->formats({format1 => sub { }, format2 => sub {}});
    $formats = $dbi->formats;

This method is generally used to get a format.

    $filter = $dbi->formats->{datetime};

If you add format, use resist_format method.

=head2 default_query_filter

Binding filter

    $dbi                 = $dbi->default_query_filter($default_query_filter);
    $default_query_filter = $dbi->default_query_filter

The following is bind filter example
    
    $dbi->resist_filter(encode_utf8 => sub {
        my $value = shift;
        
        require Encode 'encode_utf8';
        
        return encode_utf8($value);
    });
    
    $dbi->default_query_filter('encode_utf8')

Bind filter arguemts is

    1. $value : Value
    2. $key   : Key
    3. $dbi   : DBIx::Custom object
    4. $infos : {table => $table, column => $column}

=head2 default_fetch_filter

Fetching filter

    $dbi                  = $dbi->default_fetch_filter($default_fetch_filter);
    $default_fetch_filter = $dbi->default_fetch_filter;

The following is fetch filter example

    $dbi->resist_filter(decode_utf8 => sub {
        my $value = shift;
        
        require Encode 'decode_utf8';
        
        return decode_utf8($value);
    });

    $dbi->default_fetch_filter('decode_utf8');

Bind filter arguemts is

    1. $value : Value
    2. $key   : Key
    3. $dbi   : DBIx::Custom object
    4. $infos : {type => $table, sth => $sth, index => $index}

=head2 result_class

Resultset class

    $dbi          = $dbi->result_class('DBIx::Custom::Result');
    $result_class = $dbi->result_class;

Default is L<DBIx::Custom::Result>

=head2 dbh

Database handle
    
    $dbi = $dbi->dbh($dbh);
    $dbh = $dbi->dbh;
    
=head2 query_cache_max

Query cache max

    $class           = DBIx::Custom->query_cache_max(50);
    $query_cache_max = DBIx::Custom->query_cache_max;

Default value is 50

=head1 METHODS

This class is L<Object::Simple> subclass.
You can use all methods of L<Object::Simple>

=head2 connect

Connect to database

    $dbi->connect;

=head2 disconnect

Disconnect database

    $dbi->disconnect;

If database is already disconnected, this method do nothing.

=head2 reconnect

Reconnect to database

    $dbi->reconnect;

=head2 connected

Check if database is connected.
    
    $is_connected = $dbi->connected;
    
=head2 resist_filter

Resist filter
    
    $dbi->resist_filter($fname1 => $filter1, $fname => $filter2);
    
The following is resist_filter example

    $dbi->resist_filter(
        encode_utf8 => sub {
            my ($value, $key, $dbi, $infos) = @_;
            utf8::upgrade($value) unless Encode::is_utf8($value);
            return encode('UTF-8', $value);
        },
        decode_utf8 => sub {
            my ($value, $key, $dbi, $infos) = @_;
            return decode('UTF-8', $value)
        }
    );

=head2 resist_format

Add format

    $dbi->resist_format($fname1 => $format, $fname2 => $format2);
    
The following is resist_format example.

    $dbi->resist_format(date => '%Y:%m:%d', datetime => '%Y-%m-%d %H:%M:%S');

=head2 create_query
    
Create Query object parsing SQL template

    my $query = $dbi->create_query("select * from authors where {= name} and {= age}");

$query is <DBIx::Query> object. This is executed by query method as the following

    $dbi->execute($query, $params);

If you know SQL template, see also L<DBIx::Custom::SQLTemplate>.

=head2 execute

Query

    $result = $dbi->execute($template, $params);

The following is query example

    $result = $dbi->execute("select * from authors where {= name} and {= age}", 
                          {author => 'taro', age => 19});
    
    while (my @row = $result->fetch) {
        # do something
    }

If you now syntax of template, See also L<DBIx::Custom::SQLTemplate>

execute() return L<DBIx::Custom::Result> object

=head2 transaction

Get L<DBIx::Custom::Transaction> object, and you run a transaction.

    $dbi->transaction->run(sub {
        my $dbi = shift;
        
        # do something
    });

If transaction is success, commit is execute. 
If tranzation is died, rollback is execute.

=head2 create_table

Create table

    $dbi->create_table(
        'books',
        'name char(255)',
        'age  int'
    );

First argument is table name. Rest arguments is column definition.

=head2 drop_table

Drop table

    $dbi->drop_table('books');

=head2 insert

Insert row

    $affected = $dbi->insert($table, \%$insert_params);
    $affected = $dbi->insert($table, \%$insert_params, $append);

Retrun value is affected rows count
    
The following is insert example.

    $dbi->insert('books', {title => 'Perl', author => 'Taro'});

You can add statement.

    $dbi->insert('books', {title => 'Perl', author => 'Taro'}, "some statement");

=head2 update

Update rows

    $affected = $dbi->update($table, \%update_params, \%where);
    $affected = $dbi->update($table, \%update_params, \%where, $append);

Retrun value is affected rows count

The following is update example.

    $dbi->update('books', {title => 'Perl', author => 'Taro'}, {id => 5});

You can add statement.

    $dbi->update('books', {title => 'Perl', author => 'Taro'},
                 {id => 5}, "some statement");

=head2 update_all

Update all rows

    $affected = $dbi->update_all($table, \%updat_params);

Retrun value is affected rows count

The following is update_all example.

    $dbi->update_all('books', {author => 'taro'});

=head2 delete

Delete rows

    $affected = $dbi->delete($table, \%where);
    $affected = $dbi->delete($table, \%where, $append);

Retrun value is affected rows count
    
The following is delete example.

    $dbi->delete('books', {id => 5});

You can add statement.

    $dbi->delete('books', {id => 5}, "some statement");

=head2 delete_all

Delete all rows

    $affected = $dbi->delete_all($table);

Retrun value is affected rows count

The following is delete_all example.

    $dbi->delete_all('books');

=head2 select
    
Select rows

    $resut = $dbi->select(
        $table,                # must be string or array;
        \@$columns,            # must be array reference. this can be ommited
        \%$where_params,       # must be hash reference.  this can be ommited
        $append_statement,     # must be string.          this can be ommited
        $query_edit_callback   # must be code reference.  this can be ommited
    );

$reslt is L<DBIx::Custom::Result> object

The following is some select examples

    # select * from books;
    $result = $dbi->select('books');
    
    # select * from books where title = 'Perl';
    $result = $dbi->select('books', {title => 1});
    
    # select title, author from books where id = 1 for update;
    $result = $dbi->select(
        'books',              # table
        ['title', 'author'],  # columns
        {id => 1},            # where clause
        'for update',         # append statement
    );

You can join multi tables
    
    $result = $dbi->select(
        ['table1', 'table2'],                # tables
        ['table1.id as table1_id', 'title'], # columns (alias is ok)
        {table1.id => 1},                    # where clase
        "where table1.id = table2.id",       # join clause (must start 'where')
    );

You can also edit query
        
    $dbi->select(
        'books',
        # column, where clause, append statement,
        sub {
            my $query = shift;
            $query->query_filter(sub {
                # ...
            });
        }
    }

=head2 run_transaction

=head1 DBIx::Custom default configuration

DBIx::Custom have DBI object.
This module is work well in the following DBI condition.

    1. AutoCommit is true
    2. RaiseError is true

By default, Both AutoCommit and RaiseError is true.
You must not change these mode not to damage your data.

If you change these mode, 
you cannot get correct error message, 
or run_transaction may fail.

=head1 Inheritance of DBIx::Custom

DBIx::Custom is customizable DBI.
You can inherit DBIx::Custom and custumize attributes.

    package DBIx::Custom::Yours;
    use base DBIx::Custom;
    
    my $class = __PACKAGE__;
    
    $class->user('your_name');
    $class->password('your_password');

=head1 AUTHOR

Yuki Kimoto, C<< <kimoto.yuki at gmail.com> >>

Github L<http://github.com/yuki-kimoto>

I develope this module L<http://github.com/yuki-kimoto/DBIx-Custom>

=head1 COPYRIGHT & LICENSE

Copyright 2009 Yuki Kimoto, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut
