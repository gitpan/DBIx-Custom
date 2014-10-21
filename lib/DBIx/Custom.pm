package DBIx::Custom;

our $VERSION = '0.1658';

use 5.008001;
use strict;
use warnings;

use base 'Object::Simple';

use Carp 'croak';
use DBI;
use DBIx::Custom::Result;
use DBIx::Custom::Query;
use DBIx::Custom::QueryBuilder;
use DBIx::Custom::Where;
use DBIx::Custom::Model;
use DBIx::Custom::Tag;
use DBIx::Custom::Util;
use Encode qw/encode_utf8 decode_utf8/;

__PACKAGE__->attr(
    [qw/data_source dbh password user/],
    cache => 1,
    dbi_option => sub { {} },
    default_dbi_option => sub {{
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1
    }},
    models => sub { {} },
    query_builder => sub { DBIx::Custom::QueryBuilder->new },
    result_class  => 'DBIx::Custom::Result',
    safety_character => '\w',
    stash => sub { {} }
);

__PACKAGE__->attr(
    cache_method => sub {
        sub {
            my $self = shift;
            
            $self->{_cached} ||= {};
            
            if (@_ > 1) {
                $self->{_cached}{$_[0]} = $_[1] 
            }
            else {
                return $self->{_cached}{$_[0]}
            }
        }
    }
);

__PACKAGE__->attr(
    filters => sub {
        {
            encode_utf8 => sub { encode_utf8($_[0]) },
            decode_utf8 => sub { decode_utf8($_[0]) }
        }
    }
);

our $AUTOLOAD;
sub AUTOLOAD {
    my $self = shift;

    # Method name
    my ($package, $mname) = $AUTOLOAD =~ /^([\w\:]+)\:\:(\w+)$/;

    # Method
    $self->{_methods} ||= {};
    if (my $method = $self->{_methods}->{$mname}) {
        return $self->$method(@_)
    }
    elsif ($self->dbh->can($mname)) {
        $self->dbh->$mname(@_);
    }
    else {
        croak qq/Can't locate object method "$mname" via "$package"/
    }
}

sub apply_filter {
    my ($self, $table, @cinfos) = @_;

    # Initialize filters
    $self->{filter} ||= {};
    $self->{filter}{out} ||= {};
    $self->{filter}{in} ||= {};
    $self->{filter}{end} ||= {};
    
    # Create filters
    my $usage = "Usage: \$dbi->apply_filter(" .
                "TABLE, COLUMN1, {in => INFILTER1, out => OUTFILTER1, end => ENDFILTER1}, " .
                "COLUMN2, {in => INFILTER2, out => OUTFILTER2, end => ENDFILTER2}, ...)";

    for (my $i = 0; $i < @cinfos; $i += 2) {
        
        # Column
        my $column = $cinfos[$i];
        
        if (ref $column eq 'ARRAY') {
            foreach my $c (@$column) {
                push @cinfos, $c, $cinfos[$i + 1];
            }
            next;
        }
        
        # Filter info
        my $finfo = $cinfos[$i + 1] || {};
        croak "$usage (table: $table)" unless  ref $finfo eq 'HASH';
        foreach my $ftype (keys %$finfo) {
            croak "$usage (table: $table 2)" unless $ftype eq 'in' || $ftype eq 'out'
                             || $ftype eq 'end'; 
        }
        
        foreach my $way (qw/in out end/) {
            my $filter = $finfo->{$way};
            
            # State
            my $state = !exists $finfo->{$way} ? 'not_exists'
                      : !defined $filter        ? 'not_defined'
                      : ref $filter eq 'CODE'   ? 'code'
                      : 'name';
            
            next if $state eq 'not_exists';
            
            # Check filter
            croak qq{Filter "$filter" is not registered}
              if  $state eq 'name'
               && ! exists $self->filters->{$filter};
            
            # Filter
            my $f = $state eq 'not_defined' ? undef
                  : $state eq 'code'        ? $filter
                  : $self->filters->{$filter};
            $self->{filter}{$way}{$table}{$column} = $f;
            $self->{filter}{$way}{$table}{"$table.$column"} = $f;
            $self->{filter}{$way}{$table}{"${table}__$column"} = $f;
        }
    }
    
    return $self;
}

sub method {
    my $self = shift;
    
    # Merge
    my $methods = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $self->{_methods} = {%{$self->{_methods} || {}}, %$methods};
    
    return $self;
}

sub connect {
    my $self = ref $_[0] ? shift : shift->new(@_);;
    
    # Attributes
    my $data_source = $self->data_source;
    croak qq{"data_source" must be specified to connect()"}
      unless $data_source;
    my $user        = $self->user;
    my $password    = $self->password;
    my $dbi_option = {%{$self->dbi_options}, %{$self->dbi_option}};
    
    # Connect
    my $dbh = eval {DBI->connect(
        $data_source,
        $user,
        $password,
        {
            %{$self->default_dbi_option},
            %$dbi_option
        }
    )};
    
    # Connect error
    croak $@ if $@;
    
    # Database handle
    $self->dbh($dbh);
    
    return $self;
}

sub create_query {
    my ($self, $source) = @_;
    
    # Cache
    my $cache = $self->cache;
    
    # Create query
    my $query;
    if ($cache) {
        
        # Get query
        my $q = $self->cache_method->($self, $source);
        
        # Create query
        if ($q) {
            $query = DBIx::Custom::Query->new($q);
            $query->filters($self->filters);
        }
    }
    
    unless ($query) {

        # Create SQL object
        my $builder = $self->query_builder;
        
        # Create query
        $query = $builder->build_query($source);

        # Cache query
        $self->cache_method->($self, $source,
                             {sql     => $query->sql, 
                              columns => $query->columns,
                              tables  => $query->tables})
          if $cache;
    }
    
    # Prepare statement handle
    my $sth;
    eval { $sth = $self->dbh->prepare($query->{sql})};
    $self->_croak($@, qq{. Following SQL is executed. "$query->{sql}"}) if $@;
    
    # Set statement handle
    $query->sth($sth);
    
    # Set filters
    $query->filters($self->filters);
    
    return $query;
}

our %VALID_DELETE_ARGS
  = map { $_ => 1 } qw/table where append filter allow_delete_all query/;

sub delete {
    my ($self, %args) = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_DELETE_ARGS{$name};
    }
    
    # Arguments
    my $table            = $args{table} || '';
    croak qq{"table" option must be specified} unless $table;
    my $where            = $args{where} || {};
    my $append           = $args{append};
    my $filter           = $args{filter};
    my $allow_delete_all = $args{allow_delete_all};

    # Where
    my $w;
    if (ref $where eq 'HASH') {
        my $clause = ['and'];
        push @$clause, "{= $_}" for keys %$where;
        $w = $self->where;
        $w->clause($clause);
        $w->param($where);
    }
    elsif (ref $where eq 'DBIx::Custom::Where') {
        $w = $where;
        $where = $w->param;
    }    
    croak qq{"where" must be hash refernce or DBIx::Custom::Where object}
      unless ref $w eq 'DBIx::Custom::Where';
    
    # String where
    my $swhere = "$w";
    
    croak qq{"where" must be specified}
      if $swhere eq '' && !$allow_delete_all;

    # SQL stack
    my @sql;

    # Delete
    push @sql, "delete from $table $swhere";
    push @sql, $append if $append;
    
    my $sql = join(' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $args{query};
    
    # Execute query
    my $ret_val = $self->execute(
        $query, param  => $where, filter => $filter,
        table => $table);
    
    return $ret_val;
}

sub delete_all { shift->delete(allow_delete_all => 1, @_) }

our %VALID_DELETE_AT_ARGS
  = map { $_ => 1 } qw/table where append filter query
                       primary_key param/;

sub delete_at {
    my ($self, %args) = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_DELETE_AT_ARGS{$name};
    }
    
    # Primary key
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    
    # Where clause
    my $where = {};
    if (exists $args{where}) {
        my $where_columns = delete $args{where};
        $where_columns = [$where_columns] unless ref $where_columns;

        croak qq{"where" must be constant value or array reference}
          unless !ref $where_columns || ref $where_columns eq 'ARRAY';
        
        for(my $i = 0; $i < @$primary_keys; $i ++) {
           $where->{$primary_keys->[$i]} = $where_columns->[$i];
        }
    }
    
    if (exists $args{param}) {
        my $param = delete $args{param};
        
        for(my $i = 0; $i < @$primary_keys; $i ++) {
            delete $param->{$primary_keys->[$i]};
        }
    }
    
    return $self->delete(where => $where, %args);
}

sub DESTROY { }

our %VALID_EXECUTE_ARGS = map { $_ => 1 } qw/param filter table/;

sub execute{
    my ($self, $query, %args)  = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_EXECUTE_ARGS{$name};
    }
    
    my $params = $args{param} || {};
    
    # First argument is the soruce of SQL
    $query = $self->create_query($query)
      unless ref $query;
    
    # Applied filter
    my $filter = {};
    
    my $tables = $query->tables;
    my $arg_tables = $args{table} || [];
    $arg_tables = [$arg_tables]
      unless ref $arg_tables eq 'ARRAY';
    push @$tables, @$arg_tables;

    # Organize tables
    my %table_set = map {defined $_ ? ($_ => 1) : ()} @$tables;
    my $main_table = pop @$tables;
    delete $table_set{$main_table} if $main_table;
    $tables = [keys %table_set];
    push @$tables, $main_table if $main_table;
    
    foreach my $table (@$tables) {
        next unless $table;
        $filter = {
            %$filter,
            %{$self->{filter}{out}->{$table} || {}}
        }
    }
    
    # Filter argument
    my $f = DBIx::Custom::Util::array_filter_to_hash($args{filter})
         || $query->filter || {};
    foreach my $column (keys %$f) {
        my $fname = $f->{$column};
        if (!defined $fname) {
            $f->{$column} = undef;
        }
        elsif (ref $fname ne 'CODE') {
          croak qq{Filter "$fname" is not registered"}
            unless exists $self->filters->{$fname};
          
          $f->{$column} = $self->filters->{$fname};
        }
    }
    $filter = {%$filter, %$f};
    
    # Bind
    my $bind = $self->_bind($params, $query->columns, $filter);
    
    # Execute
    my $sth = $query->sth;
    my $affected;
    eval {$affected = $sth->execute(@$bind)};
    $self->_croak($@, qq{. Following SQL is executed. "$query->{sql}"}) if $@;
    
    # Return resultset if select statement is executed
    if ($sth->{NUM_OF_FIELDS}) {
        
        # Result in and end filter
        my $in_filter  = {};
        my $end_filter = {};
        foreach my $table (@$tables) {
            next unless $table;
            $in_filter = {
                %$in_filter,
                %{$self->{filter}{in}{$table} || {}}
            };
            $end_filter = {
                %$end_filter,
                %{$self->{filter}{end}{$table} || {}}
            };
        }
        
        # Result
        my $result = $self->result_class->new(
            sth            => $sth,
            filters        => $self->filters,
            filter_check   => $self->filter_check,
            default_filter => $self->{default_in_filter},
            filter         => $in_filter || {},
            end_filter     => $end_filter || {}
        );

        return $result;
    }
    return $affected;
}

our %VALID_INSERT_ARGS = map { $_ => 1 } qw/table param append
                                            filter query/;
sub insert {
    my ($self, %args) = @_;

    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_INSERT_ARGS{$name};
    }
    
    # Arguments
    my $table  = $args{table};
    croak qq{"table" option must be specified} unless $table;
    my $param  = $args{param} || {};
    my $append = $args{append} || '';
    my $filter = $args{filter};
    
    # Columns
    my @columns;
    my $safety = $self->safety_character;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name}
          unless $column =~ /^[$safety\.]+$/;
        push @columns, $column;
    }
    
    # SQL stack
    my @sql;
    
    # Insert
    push @sql, "insert into $table {insert_param ". join(' ', @columns) . '}';
    push @sql, $append if $append;
    
    # SQL
    my $sql = join (' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $args{query};
    
    # Execute query
    my $ret_val = $self->execute(
        $query,
        param  => $param,
        filter => $filter,
        table => $table
    );
    
    return $ret_val;
}

our %VALID_INSERT_AT_ARGS
  = map { $_ => 1 } qw/table param
                       where append filter query
                       primary_key param/;

sub insert_at {
    my ($self, %args) = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_INSERT_AT_ARGS{$name};
    }
    
    # Primary key
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    
    # Where clause
    my $where = {};
    my $param = {};
    
    if (exists $args{where}) {
        my $where_columns = delete $args{where};
        $where_columns = [$where_columns] unless ref $where_columns;

        croak qq{"where" must be constant value or array reference}
          unless !ref $where_columns || ref $where_columns eq 'ARRAY';
        
        for(my $i = 0; $i < @$primary_keys; $i ++) {
           $where->{$primary_keys->[$i]} = $where_columns->[$i];
        }
    }
    
    if (exists $args{param}) {
        $param = delete $args{param};
        for(my $i = 0; $i < @$primary_keys; $i ++) {
             delete $param->{$primary_keys->[$i]};
        }
    }
    
    $param = {%$param, %$where};
    
    return $self->insert(param => $param, %args);
}

sub insert_param {
    my ($self, $param) = @_;
    
    # Insert paramter tag
    my @tag;
    push @tag, '{insert_param';
    my $safety = $self->safety_character;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name}
          unless $column =~ /^[$safety\.]+$/;
        push @tag, $column;
    }
    push @tag, '}';
    
    return join ' ', @tag;
}

sub each_column {
    my ($self, $cb) = @_;
    
    # Iterate all tables
    my $sth_tables = $self->dbh->table_info;
    while (my $table_info = $sth_tables->fetchrow_hashref) {
        
        # Table
        my $table = $table_info->{TABLE_NAME};
        
        # Iterate all columns
        my $sth_columns = $self->dbh->column_info(undef, undef, $table, '%');
        while (my $column_info = $sth_columns->fetchrow_hashref) {
            my $column = $column_info->{COLUMN_NAME};
            $self->$cb($table, $column, $column_info);
        }
    }
}

sub new {
    my $self = shift->SUPER::new(@_);
    
    # Check attribute names
    my @attrs = keys %$self;
    foreach my $attr (@attrs) {
        croak qq{"$attr" is invalid attribute name}
          unless $self->can($attr);
    }

    $self->register_tag(
        '?'     => \&DBIx::Custom::Tag::placeholder,
        '='     => \&DBIx::Custom::Tag::equal,
        '<>'    => \&DBIx::Custom::Tag::not_equal,
        '>'     => \&DBIx::Custom::Tag::greater_than,
        '<'     => \&DBIx::Custom::Tag::lower_than,
        '>='    => \&DBIx::Custom::Tag::greater_than_equal,
        '<='    => \&DBIx::Custom::Tag::lower_than_equal,
        'like'  => \&DBIx::Custom::Tag::like,
        'in'    => \&DBIx::Custom::Tag::in,
        'insert_param' => \&DBIx::Custom::Tag::insert_param,
        'update_param' => \&DBIx::Custom::Tag::update_param
    );
    
    return $self;
}

sub not_exists { bless {}, 'DBIx::Custom::NotExists' }

sub register_filter {
    my $invocant = shift;
    
    # Register filter
    my $filters = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $invocant->filters({%{$invocant->filters}, %$filters});
    
    return $invocant;
}

sub register_tag { shift->query_builder->register_tag(@_) }

our %VALID_SELECT_ARGS
  = map { $_ => 1 } qw/table column where append relation filter query selection join/;

sub _need_tables {
    my ($self, $tree, $need_tables, $tables) = @_;
    
    foreach my $table (@$tables) {
        
        if ($tree->{$table}) {
            $need_tables->{$table} = 1;
            $self->_need_tables($tree, $need_tables, [$tree->{$table}{parent}])
        }
    }
}

sub select {
    my ($self, %args) = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_SELECT_ARGS{$name};
    }
    
    # Arguments
    my $table = $args{table};
    my $tables = ref $table eq 'ARRAY' ? $table
               : defined $table ? [$table]
               : [];
    my $columns   = $args{column} || [];
    $columns = [$columns] unless ref $columns;
    my $selection = $args{selection} || '';
    my $where     = $args{where} || {};
    my $append    = $args{append};
    my $filter    = $args{filter};
    my $join =     $args{join} || [];
    croak qq{"join" must be array reference}
      unless ref $join eq 'ARRAY';
    
    # Add relation tables(DEPRECATED!);
    $self->_add_relation_table($tables, $args{relation});
    
    # SQL stack
    my @sql;
    push @sql, 'select';
    
    # Selection
    if ($selection) { 
        push @sql, $selection;
        if ($selection =~ /from\s+(?:\{table\s+)?([^\s\{]+?)\b/) {
             unshift @$tables, $1;
        }
        unshift @$tables, @{$self->_tables($selection)};
    }
    
    # Column names and table name
    else {
        # Column names
        if (@$columns) {
            foreach my $column (@$columns) {
                unshift @$tables, @{$self->_tables($column)};
                push @sql, ($column, ',');
            }
            pop @sql if $sql[-1] eq ',';
        }
        else { push @sql, '*' }
        
        # Table
        push @sql, 'from';
        if ($args{relation}) {
            my $found = {};
            foreach my $table (@$tables) {
                push @sql, ($table, ',') unless $found->{$table};
                $found->{$table} = 1;
            }
        }
        else { push @sql, $tables->[-1] }
        pop @sql if ($sql[-1] || '') eq ',';
    }
    
    # Main table
    croak "Not found table name" unless $tables->[-1];
    
    # Where
    my $w;
    if (ref $where eq 'HASH') {
        my $clause = ['and'];
        push @$clause, "{= $_}" for keys %$where;
        $w = $self->where(clause => $clause, param => $where);
    }
    elsif (ref $where eq 'DBIx::Custom::Where') {
        $w = $where;
        $where = $w->param;
    }
    
    croak qq{"where" must be hash reference or DBIx::Custom::Where object}
      unless ref $w eq 'DBIx::Custom::Where';
    
    # String where
    my $swhere = "$w";
    
    # Add table names in where clause
    unshift @$tables, @{$self->_tables($swhere)};
    
    # Push join
    $self->_push_join(\@sql, $join, $tables);
    
    # Add where clause
    push @sql, $swhere;
    
    # Relation(DEPRECATED!);
    $self->_push_relation(\@sql, $tables, $args{relation}, $swhere eq '' ? 1 : 0);
    
    # Append statement
    push @sql, $append if $append;
    
    # SQL
    my $sql = join (' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $args{query};
    
    # Execute query
    my $result = $self->execute(
        $query, param  => $where, filter => $filter,
        table => $tables);
    
    return $result;
}

our %VALID_SELECT_AT_ARGS
  = map { $_ => 1 } qw/table column where append relation filter query selection
                       param primary_key join/;

sub select_at {
    my ($self, %args) = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_SELECT_AT_ARGS{$name};
    }
    
    # Primary key
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    
    # Table
    croak qq{"table" option must be specified} unless $args{table};
    my $table = ref $args{table} ? $args{table}->[-1] : $args{table};
    
    # Where clause
    my $where = {};
    if (exists $args{where}) {
        my $where_columns = delete $args{where};
        
        croak qq{"where" must be constant value or array reference}
          unless !ref $where_columns || ref $where_columns eq 'ARRAY';
        
        $where_columns = [$where_columns] unless ref $where_columns;
        
        for(my $i = 0; $i < @$primary_keys; $i ++) {
           $where->{$table . '.' . $primary_keys->[$i]} = $where_columns->[$i];
        }
    }
    
    if (exists $args{param}) {
        my $param = delete $args{param};
        for(my $i = 0; $i < @$primary_keys; $i ++) {
             delete $param->{$primary_keys->[$i]};
        }
    }
    
    return $self->select(where => $where, %args);
}

sub model {
    my ($self, $name, $model) = @_;
    
    # Set
    if ($model) {
        $self->models->{$name} = $model;
        return $self;
    }
    
    # Check model existance
    croak qq{Model "$name" is not included}
      unless $self->models->{$name};
    
    # Get
    return $self->models->{$name};
}

sub include_model {
    my ($self, $name_space, $model_infos) = @_;
    
    $name_space ||= '';
    unless ($model_infos) {
        # Load name space module
        croak qq{"$name_space" is invalid class name}
          if $name_space =~ /[^\w:]/;
        eval "use $name_space";
        croak qq{Name space module "$name_space.pm" is needed. $@} if $@;
        
        # Search model modules
        my $path = $INC{"$name_space.pm"};
        $path =~ s/\.pm$//;
        opendir my $dh, $path
          or croak qq{Can't open directory "$path": $!};
        $model_infos = [];
        while (my $module = readdir $dh) {
            push @$model_infos, $module
              if $module =~ s/\.pm$//;
        }
        
        close $dh;
    }
    
    foreach my $model_info (@$model_infos) {
        
        # Model class, name, table
        my $model_class;
        my $model_name;
        my $model_table;
        if (ref $model_info eq 'HASH') {
            $model_class = $model_info->{class};
            $model_name  = $model_info->{name};
            $model_table = $model_info->{table};
            
            $model_name  ||= $model_class;
            $model_table ||= $model_name;
        }
        else { $model_class =$model_name = $model_table = $model_info }
        my $mclass = "${name_space}::$model_class";
        
        # Load
        croak qq{"$mclass" is invalid class name}
          if $mclass =~ /[^\w:]/;
        unless ($mclass->can('isa')) {
            eval "use $mclass";
            croak $@ if $@;
        }
        
        # Instantiate
        my $model = $mclass->new(dbi => $self);
        $model->name($model_name) unless $model->name;
        $model->table($model_table) unless $model->table;
        
        # Set
        $self->model($model->name, $model);
        
        # Apply filter
        croak "${name_space}::$model_class filter must be array reference"
          unless ref $model->filter eq 'ARRAY';
        $self->apply_filter($model->table, @{$model->filter});
    }
    return $self;
}

sub setup_model {
    my $self = shift;
    
    $self->each_column(
        sub {
            my ($self, $table, $column, $column_info) = @_;
            
            if (my $model = $self->models->{$table}) {
                push @{$model->columns}, $column;
            }
        }
    );
    return $self;
}

our %VALID_UPDATE_ARGS
  = map { $_ => 1 } qw/table param
                       where append filter allow_update_all query/;

sub update {
    my ($self, %args) = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_UPDATE_ARGS{$name};
    }
    
    # Arguments
    my $table            = $args{table} || '';
    croak qq{"table" option must be specified} unless $table;
    my $param            = $args{param} || {};
    my $where            = $args{where} || {};
    my $append           = $args{append} || '';
    my $filter           = $args{filter};
    my $allow_update_all = $args{allow_update_all};
    
    # Update keys
    my @clumns = keys %$param;

    # Columns
    my @columns;
    my $safety = $self->safety_character;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name}
          unless $column =~ /^[$safety\.]+$/;
        push @columns, $column;
    }
        
    # Update clause
    my $update_clause = '{update_param ' . join(' ', @clumns) . '}';

    # Where
    my $w;
    if (ref $where eq 'HASH') {
        my $clause = ['and'];
        push @$clause, "{= $_}" for keys %$where;
        $w = $self->where;
        $w->clause($clause);
        $w->param($where);
    }
    elsif (ref $where eq 'DBIx::Custom::Where') {
        $w = $where;
        $where = $w->param;
    }  
    
    croak qq{"where" must be hash refernce or DBIx::Custom::Where object}
      unless ref $w eq 'DBIx::Custom::Where';
    
    # String where
    my $swhere = "$w";
    
    croak qq{"where" must be specified}
      if "$swhere" eq '' && !$allow_update_all;
    
    # SQL stack
    my @sql;
    
    # Update
    push @sql, "update $table $update_clause $swhere";
    push @sql, $append if $append;
    
    # Rearrange parameters
    foreach my $wkey (keys %$where) {
        
        if (exists $param->{$wkey}) {
            $param->{$wkey} = [$param->{$wkey}]
              unless ref $param->{$wkey} eq 'ARRAY';
            
            push @{$param->{$wkey}}, $where->{$wkey};
        }
        else {
            $param->{$wkey} = $where->{$wkey};
        }
    }
    
    # SQL
    my $sql = join(' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $args{query};
    
    # Execute query
    my $ret_val = $self->execute($query, param  => $param, 
                                 filter => $filter,
                                 table => $table);
    
    return $ret_val;
}

sub update_all { shift->update(allow_update_all => 1, @_) };

our %VALID_UPDATE_AT_ARGS
  = map { $_ => 1 } qw/table param
                       where append filter query
                       primary_key param/;

sub update_at {
    my ($self, %args) = @_;
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{Argument "$name" is invalid name}
          unless $VALID_UPDATE_AT_ARGS{$name};
    }
    
    # Primary key
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    
    # Where clause
    my $where = {};
    my $param = {};
    
    if (exists $args{where}) {
        my $where_columns = delete $args{where};
        $where_columns = [$where_columns] unless ref $where_columns;

        croak qq{"where" must be constant value or array reference}
          unless !ref $where_columns || ref $where_columns eq 'ARRAY';
        
        for(my $i = 0; $i < @$primary_keys; $i ++) {
           $where->{$primary_keys->[$i]} = $where_columns->[$i];
        }
    }
    
    if (exists $args{param}) {
        $param = delete $args{param};
        for(my $i = 0; $i < @$primary_keys; $i ++) {
            delete $param->{$primary_keys->[$i]};
        }
    }
    
    return $self->update(where => $where, param => $param, %args);
}

sub update_param {
    my ($self, $param) = @_;
    
    # Update parameter tag
    my @tag;
    push @tag, '{update_param';
    my $safety = $self->safety_character;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name}
          unless $column =~ /^[$safety\.]+$/;
        push @tag, $column;
    }
    push @tag, '}';
    
    return join ' ', @tag;
}

sub where {
    my $self = shift;

    return DBIx::Custom::Where->new(
        query_builder => $self->query_builder,
        safety_character => $self->safety_character,
        @_
    );
}

sub _bind {
    my ($self, $params, $columns, $filter) = @_;
    
    # bind values
    my @bind;
    
    # Build bind values
    my $count = {};
    my $not_exists = {};
    foreach my $column (@$columns) {
        
        # Value
        my $value;
        if(ref $params->{$column} eq 'ARRAY') {
            my $i = $count->{$column} || 0;
            $i += $not_exists->{$column} || 0;
            my $found;
            for (my $k = $i; $i < @{$params->{$column}}; $k++) {
                if (ref $params->{$column}->[$k] eq 'DBIx::Custom::NotExists') {
                    $not_exists->{$column}++;
                }
                else  {
                    $value = $params->{$column}->[$k];
                    $found = 1;
                    last
                }
            }
            next unless $found;
        }
        else { $value = $params->{$column} }
        
        # Filter
        my $f = $filter->{$column} || $self->{default_out_filter} || '';
        
        push @bind, $f ? $f->($value) : $value;
        
        # Count up 
        $count->{$column}++;
    }
    
    return \@bind;
}

sub _croak {
    my ($self, $error, $append) = @_;
    $append ||= "";
    
    # Verbose
    if ($Carp::Verbose) { croak $error }
    
    # Not verbose
    else {
        
        # Remove line and module infromation
        my $at_pos = rindex($error, ' at ');
        $error = substr($error, 0, $at_pos);
        $error =~ s/\s+$//;
        
        croak "$error$append";
    }
}

sub _tables {
    my ($self, $source) = @_;
    
    my $tables = [];
    
    my $safety_character = $self->safety_character;
    
    while ($source =~ /\b($safety_character+)\./g) {
        push @$tables, $1;
    }
    
    return $tables;
}

sub _push_join {
    my ($self, $sql, $join, $join_tables) = @_;
    
    return unless @$join;
    
    my $tree = {};
    
    for (my $i = 0; $i < @$join; $i++) {
        
        my $join_clause = $join->[$i];
        
        if ($join_clause =~ /\s([^\.\s]+?)\..+\s([^\.\s]+?)\..+?$/) {
            
            my $table1 = $1;
            my $table2 = $2;
            
            croak qq{right side table of "$join_clause" must be uniq}
              if exists $tree->{$table2};
            
            $tree->{$table2}
              = {position => $i, parent => $table1, join => $join_clause};
        }
        else {
            croak qq{join "$join_clause" must be two table name};
        }
    }
    
    my $need_tables = {};
    $self->_need_tables($tree, $need_tables, $join_tables);
    
    my @need_tables = sort { $tree->{$a}{position} <=> $tree->{$b}{position} } keys %$need_tables;

    foreach my $need_table (@need_tables) {
        push @$sql, $tree->{$need_table}{join};
    }
}

# DEPRECATED!
__PACKAGE__->attr(
    dbi_options => sub { {} },
    filter_check  => 1
);

# DEPRECATED!
sub default_bind_filter {
    my $self = shift;
    
    if (@_) {
        my $fname = $_[0];
        
        if (@_ && !$fname) {
            $self->{default_out_filter} = undef;
        }
        else {
            croak qq{Filter "$fname" is not registered}
              unless exists $self->filters->{$fname};
        
            $self->{default_out_filter} = $self->filters->{$fname};
        }
        return $self;
    }
    
    return $self->{default_out_filter};
}

# DEPRECATED!
sub default_fetch_filter {
    my $self = shift;
    
    if (@_) {
        my $fname = $_[0];

        if (@_ && !$fname) {
            $self->{default_in_filter} = undef;
        }
        else {
            croak qq{Filter "$fname" is not registered}
              unless exists $self->filters->{$fname};
        
            $self->{default_in_filter} = $self->filters->{$fname};
        }
        
        return $self;
    }
    
    return $self->{default_in_filter};
}

# DEPRECATED!
sub register_tag_processor {
    return shift->query_builder->register_tag_processor(@_);
}

# DEPRECATED!
sub _push_relation {
    my ($self, $sql, $tables, $relation, $need_where) = @_;
    
    if (keys %{$relation || {}}) {
        push @$sql, $need_where ? 'where' : 'and';
        foreach my $rcolumn (keys %$relation) {
            my $table1 = (split (/\./, $rcolumn))[0];
            my $table2 = (split (/\./, $relation->{$rcolumn}))[0];
            push @$tables, ($table1, $table2);
            push @$sql, ("$rcolumn = " . $relation->{$rcolumn},  'and');
        }
    }
    pop @$sql if $sql->[-1] eq 'and';    
}

# DEPRECATED!
sub _add_relation_table {
    my ($self, $tables, $relation) = @_;
    
    if (keys %{$relation || {}}) {
        foreach my $rcolumn (keys %$relation) {
            my $table1 = (split (/\./, $rcolumn))[0];
            my $table2 = (split (/\./, $relation->{$rcolumn}))[0];
            my $table1_exists;
            my $table2_exists;
            foreach my $table (@$tables) {
                $table1_exists = 1 if $table eq $table1;
                $table2_exists = 1 if $table eq $table2;
            }
            unshift @$tables, $table1 unless $table1_exists;
            unshift @$tables, $table2 unless $table2_exists;
        }
    }
}

1;

=head1 NAME

DBIx::Custom - Useful database access, respecting SQL!

=head1 SYNOPSYS

    use DBIx::Custom;
    
    # Connect
    my $dbi = DBIx::Custom->connect(
        data_source => "dbi:mysql:database=dbname",
        user => 'ken',
        password => '!LFKD%$&',
        dbi_option => {mysql_enable_utf8 => 1}
    );

    # Insert 
    $dbi->insert(
        table  => 'book',
        param  => {title => 'Perl', author => 'Ken'}
    );
    
    # Update 
    $dbi->update(
        table  => 'book', 
        param  => {title => 'Perl', author => 'Ken'}, 
        where  => {id => 5},
    );
    
    # Delete
    $dbi->delete(
        table  => 'book',
        where  => {author => 'Ken'},
    );

    # Select
    my $result = $dbi->select(
        table  => 'book',
        where  => {author => 'Ken'},
    );

    # Select, more complex
    my $result = $dbi->select(
        table  => 'book',
        column => [
            'book.author as book__author',
            'company.name as company__name'
        ],
        where  => {'book.author' => 'Ken'},
        join => ['left outer join company on book.company_id = company.id'],
        append => 'order by id limit 5'
    );
    
    # Fetch
    while (my $row = $result->fetch) {
        
    }
    
    # Fetch as hash
    while (my $row = $result->fetch_hash) {
        
    }
    
    # Execute SQL with parameter.
    $dbi->execute(
        "select id from book where {= author} and {like title}",
        param  => {author => 'ken', title => '%Perl%'}
    );
    
=head1 DESCRIPTIONS

L<DBIx::Custom> is L<DBI> wrapper module.

=head1 FEATURES

=over 4

=item *

There are many basic methods to execute various queries.
C<insert()>, C<update()>, C<update_all()>,C<delete()>,
C<delete_all()>, C<select()>,
C<insert_at()>, C<update_at()>, 
C<delete_at()>, C<select_at()>, C<execute()>

=item *

Filter when data is send or receive.

=item *

Data filtering system

=item *

Model support.

=item *

Generate where clause dinamically.

=item *

Generate join clause dinamically.

=back

=head1 GUIDE

L<DBIx::Custom::Guide> - L<DBIx::Custom> Guide

=head1 Wiki

L<DBIx::Custom Wiki|https://github.com/yuki-kimoto/DBIx-Custom/wiki>

=head1 ATTRIBUTES

=head2 C<cache>

    my $cache = $dbi->cache;
    $dbi      = $dbi->cache(1);

Enable caching of L<DBIx::Custom::Query>,
default to 1.

=head2 C<data_source>

    my $data_source = $dbi->data_source;
    $dbi            = $dbi->data_source("DBI:mysql:database=dbname");

Data source, used when C<connect()> is executed.

=head2 C<dbh>

    my $dbh = $dbi->dbh;
    $dbi    = $dbi->dbh($dbh);

Database handle of L<DBI>.

=head2 C<dbi_option>

    my $dbi_option = $dbi->dbi_option;
    $dbi           = $dbi->dbi_option($dbi_option);

L<DBI> option, used when C<connect()> is executed.
Each value in option override the value of C<default_dbi_option>.

=head2 C<default_dbi_option>

    my $default_dbi_option = $dbi->default_dbi_option;
    $dbi            = $dbi->default_dbi_option($default_dbi_option);

L<DBI> default option, used when C<connect()> is executed,
default to the following values.

    {
        RaiseError => 1,
        PrintError => 0,
        AutoCommit => 1,
    }

=head2 C<filters>

    my $filters = $dbi->filters;
    $dbi        = $dbi->filters(\%filters);

Filters, registered by C<register_filter()>.

=head2 C<(experimental) models>

    my $models = $dbi->models;
    $dbi       = $dbi->models(\%models);

Models, included by C<include_model()>.

=head2 C<password>

    my $password = $dbi->password;
    $dbi         = $dbi->password('lkj&le`@s');

Password, used when C<connect()> is executed.

=head2 C<query_builder>

    my $sql_class = $dbi->query_builder;
    $dbi          = $dbi->query_builder(DBIx::Custom::QueryBuilder->new);

Query builder, default to L<DBIx::Custom::QueryBuilder> object.

=head2 C<result_class>

    my $result_class = $dbi->result_class;
    $dbi             = $dbi->result_class('DBIx::Custom::Result');

Result class, default to L<DBIx::Custom::Result>.

=head2 C<(experimental) safety_character>

    my $safety_character = $self->safety_character;
    $dbi                 = $self->safety_character($character);

Regex of safety character consist of table and column name, default to '\w'.
Note that you don't have to specify like '[\w]'.

=head2 C<user>

    my $user = $dbi->user;
    $dbi     = $dbi->user('Ken');

User name, used when C<connect()> is executed.

=head1 METHODS

L<DBIx::Custom> inherits all methods from L<Object::Simple>
and use all methods of L<DBI>
and implements the following new ones.

=head2 C<(experimental) apply_filter>

    $dbi->apply_filter(
        'book',
        $column1 => {out => $outfilter1, in => $infilter1, end => $endfilter1}
        $column2 => {out => $outfilter2, in => $infilter2, end => $endfilter2}
        ...,
    );

Apply filter to specified column, C<out> is the direction from perl to database,
C<in> is the direction from database to perl,
C<end> is filter after C<in> filter.

You can use three column name to apply filter to column data.

                       (Example)
    1. column        : author
    2. table.column  : book.author
    3. table__column : book__author

=head2 C<connect>

    my $dbi = DBIx::Custom->connect(data_source => "dbi:mysql:database=dbname",
                                    user => 'ken', password => '!LFKD%$&');

Create a new L<DBIx::Custom> object and connect to the database.
L<DBIx::Custom> is a wrapper of L<DBI>.
C<AutoCommit> and C<RaiseError> options are true, 
and C<PrintError> option is false by default. 

=head2 C<create_query>
    
    my $query = $dbi->create_query(
        "select * from book where {= author} and {like title};"
    );

Create the instance of L<DBIx::Custom::Query> from the source of SQL.
If you want to get high performance,
use C<create_query()> method and execute it by C<execute()> method
instead of suger methods.

    $dbi->execute($query, {author => 'Ken', title => '%Perl%'});

=head2 C<execute>

    my $result = $dbi->execute($query,  param => $params, filter => \@filter);
    my $result = $dbi->execute($source, param => $params, filter => \@filter);

Execute query or the source of SQL.
Query is L<DBIx::Custom::Query> object.
Return value is L<DBIx::Custom::Result> if select statement is executed,
or the count of affected rows if insert, update, delete statement is executed.

=head2 C<delete>

    $dbi->delete(table  => $table,
                 where  => \%where,
                 append => $append,
                 filter => \@filter,
                 query  => 1);

Execute delete statement.
C<delete> method have C<table>, C<where>, C<append>, and C<filter> arguments.
C<table> is a table name.
C<where> is where clause. this must be hash reference.
C<append> is a string added at the end of the SQL statement.
C<filter> is filters when parameter binding is executed.
C<query> is if you don't execute sql and get L<DBIx::Custom::Query> object as return value.
default to 0. This is experimental.
Return value of C<delete()> is the count of affected rows.

=head2 C<delete_all>

    $dbi->delete_all(table => $table);

Execute delete statement to delete all rows.
Arguments is same as C<delete> method,
except that C<delete_all> don't have C<where> argument.
Return value of C<delete_all()> is the count of affected rows.

=head3 C<(experimental) delete_at()>

To delete row by using primary key, use C<delete_at()>

    $dbi->delete_at(
        table => 'book',
        primary_key => ['id'],
        where => ['123']
    );

In this example, row which id column is 123 is deleted.
NOTE that you must pass array reference as C<where>.

You can also write arguments like this.

    $dbi->delete_at(
        table => 'book',
        primary_key => ['id'],
        param => {id => '123'}
    );

=head2 C<insert>

    $dbi->insert(table  => $table, 
                 param  => \%param,
                 append => $append,
                 filter => \@filter,
                 query  => 1);

Execute insert statement.
C<insert> method have C<table>, C<param>, C<append>
and C<filter> arguments.
C<table> is a table name.
C<param> is the pairs of column name value. this must be hash reference.
C<append> is a string added at the end of the SQL statement.
C<filter> is filters when parameter binding is executed.
C<query> is if you don't execute sql and get L<DBIx::Custom::Query> object as return value.
default to 0. This is experimental.
This is overwrites C<default_bind_filter>.
Return value of C<insert()> is the count of affected rows.

=head3 C<(experimental) insert_at()>

To insert row by using primary key, use C<insert_at()>

    $dbi->insert_at(
        table => 'book',
        primary_key => ['id'],
        where => ['123'],
        param => {name => 'Ken'}
    );

In this example, row which id column is 123 is inserted.
NOTE that you must pass array reference as C<where>.
If C<param> contains primary key,
the key and value is delete from C<param>.

=head2 C<(experimental) insert_param>

    my $insert_param = $dbi->insert_param({title => 'a', age => 2});

Create insert parameter tag.

    {title => 'a', age => 2}   ->   {insert_param title age}

=head2 C<(experimental) each_column>

    $dbi->each_column(
        sub {
            my ($self, $table, $column, $column_info) = @_;
            
            my $type = $column_info->{TYPE_NAME};
            
            if ($type eq 'DATE') {
                # ...
            }
        }
    );
Get column informations from database.
Argument is callback.
You can do anything in callback.
Callback receive four arguments, dbi object, table name,
column name and column information.

=head2 C<(experimental) include_model>

    $dbi->include_model(
        'MyModel' => [
            'book', 'person', 'company'
        ]
    );

Include models. First argument is name space.
Second argument is array reference of class base names.

If you don't specify second argument, All models under name space is
included.

    $dbi->include_model('MyModel');

Note that in this case name spece module is needed.

    # MyModel.pm
    package MyModel;
    
    use base 'DBIx::Custom::Model';

The following model is instantiated and included.

    MyModel::book
    MyModel::person
    MyModel::company

You can get these instance by C<model()>.

    my $book_model = $dbi->model('book');

If you want to other name as model class,
you can do like this.

    $dbi->include_model(
        'MyModel' => [
            {'book' => 'Book'},
            {'person' => 'Person'}
        ]
    );

=head2 C<(experimental) method>

    $dbi->method(
        update_or_insert => sub {
            my $self = shift;
            # do something
        },
        find_or_create   => sub {
            my $self = shift;
            # do something
        }
    );

Register method. These method is called from L<DBIx::Custom> object directory.

    $dbi->update_or_insert;
    $dbi->find_or_create;

=head2 C<new>

    my $dbi = DBIx::Custom->connect(data_source => "dbi:mysql:database=dbname",
                                    user => 'ken', password => '!LFKD%$&');

Create a new L<DBIx::Custom> object.

=head2 C<(experimental) not_exists>

    my $not_exists = $dbi->not_exists;

Get DBIx::Custom::NotExists object.

=head2 C<register_filter>

    $dbi->register_filter(%filters);
    $dbi->register_filter(\%filters);
    
Register filter. Registered filters is available in the following attributes
or arguments.

=over 4

=item *

C<filter> argument of C<insert()>, C<update()>,
C<update_all()>, C<delete()>, C<delete_all()>, C<select()>
methods

=item *

C<execute()> method

=item *

C<default_filter> and C<filter> of C<DBIx::Custom::Query>

=item *

C<default_filter> and C<filter> of C<DBIx::Custom::Result>

=back

=head2 C<register_tag>

    $dbi->register_tag(
        limit => sub {
            ...;
        }
    );

Register tag.

=head2 C<rollback>

    $dbi->rollback;

Rollback transaction.
This is same as L<DBI>'s C<rollback>.

=head2 C<select>
    
    my $result = $dbi->select(
        table     => $table,
        column    => [@column],
        where     => \%where,
        append    => $append,
        relation  => \%relation,
        join => ['left outer join company on book.company_id = company.id']
        filter    => \%filter,
        query     => 1,
        selection => $selection
    );

Execute select statement.
C<select> method have C<table>, C<column>, C<where>, C<append>,
C<relation> and C<filter> arguments.
C<table> is a table name.
C<column> is column names. this is array reference or string.
C<where> is where clause. this is normally hash reference.
C<append> is a string added at the end of the SQL statement.
C<filter> is filters when parameter binding is executed.
C<query> is if you don't execute sql and get L<DBIx::Custom::Query> object as return value.
default to 0. This is experimental.
C<selection> is string of column name and tables. This is experimental

    selection => 'name, location.name as location_name ' .
                 'from company inner join location'

First element is a string. it contains tags,
such as "{= title} or {like author}".
Second element is paramters.

C<join> is join clause after from clause.
This is experimental.

=head3 C<(experimental) select_at()>

To select row by using primary key, use C<select_at()>.

    $dbi->select_at(table => 'book', primary_key => ['id'], where => ['123']);

In this example, row which id colunm is 123 is selected.
NOTE that you must pass array reference as C<where>.

=head2 C<update>

    $dbi->update(table  => $table, 
                 param  => \%params,
                 where  => \%where,
                 append => $append,
                 filter => \@filter,
                 query  => 1)

Execute update statement.
C<update> method have C<table>, C<param>, C<where>, C<append>
and C<filter> arguments.
C<table> is a table name.
C<param> is column-value pairs. this must be hash reference.
C<where> is where clause. this must be hash reference.
C<append> is a string added at the end of the SQL statement.
C<filter> is filters when parameter binding is executed.
C<query> is if you don't execute sql and get L<DBIx::Custom::Query> object as return value.
default to 0. This is experimental.
This is overwrites C<default_bind_filter>.
Return value of C<update()> is the count of affected rows.

=head2 C<(experimental) update_param>

    my $update_param = $dbi->update_param({title => 'a', age => 2});

Create update parameter tag.

    {title => 'a', age => 2}   ->   {update_param title age}

=head2 C<(experimental) model>

    $dbi->model('book')->method(
        insert => sub { ... },
        update => sub { ... }
    );
    
    my $model = $dbi->model('book');

Set and get a L<DBIx::Custom::Model> object,

=head2 C<(experimental) setup_model>

    $dbi->setup_model;

Setup all model objects.
C<columns> and C<primary_key> is automatically set.

=head2 C<update_all>

    $dbi->update_all(table  => $table, 
                     param  => \%params,
                     filter => \@filter,
                     append => $append);

Execute update statement to update all rows.
Arguments is same as C<update> method,
except that C<update_all> don't have C<where> argument.
Return value of C<update_all()> is the count of affected rows.

=head3 C<(experimental) update_at()>

To update row by using primary key, use C<update_at()>

    $dbi->update_at(
        table => 'book',
        primary_key => ['id'],
        where => ['123'],
        param => {name => 'Ken'}
    );

In this example, row which id column is 123 is updated.
NOTE that you must pass array reference as C<where>.
If C<param> contains primary key,
the key and value is delete from C<param>.

=head2 C<(experimental) where>

    my $where = $dbi->where(
        clause => ['and', '{= title}', '{= author}'],
        param => {title => 'Perl', author => 'Ken'}
    );

Create a new L<DBIx::Custom::Where> object.

=head2 C<cache_method>

    $dbi          = $dbi->cache_method(\&cache_method);
    $cache_method = $dbi->cache_method

Method to set and get caches.

=head1 Tags

The following tags is available.

=head2 C<(experimental) table>

Table tag

    {table TABLE}    ->    TABLE

This is used to teach what is applied table to C<execute()>.

=head2 C<?>

Placeholder tag.

    {? NAME}    ->   ?

=head2 C<=>

Equal tag.

    {= NAME}    ->   NAME = ?

=head2 C<E<lt>E<gt>>

Not equal tag.

    {<> NAME}   ->   NAME <> ?

=head2 C<E<lt>>

Lower than tag

    {< NAME}    ->   NAME < ?

=head2 C<E<gt>>

Greater than tag

    {> NAME}    ->   NAME > ?

=head2 C<E<gt>=>

Greater than or equal tag

    {>= NAME}   ->   NAME >= ?

=head2 C<E<lt>=>

Lower than or equal tag

    {<= NAME}   ->   NAME <= ?

=head2 C<like>

Like tag

    {like NAME}   ->   NAME like ?

=head2 C<in>

In tag.

    {in NAME COUNT}   ->   NAME in [?, ?, ..]

=head2 C<insert_param>

Insert parameter tag.

    {insert_param NAME1 NAME2}   ->   (NAME1, NAME2) values (?, ?)

=head2 C<update_param>

Updata parameter tag.

    {update_param NAME1 NAME2}   ->   set NAME1 = ?, NAME2 = ?

=head1 STABILITY

L<DBIx::Custom> is stable. APIs keep backword compatible
except experimental one in the feature.

=head1 BUGS

Please tell me bugs if found.

C<< <kimoto.yuki at gmail.com> >>

L<http://github.com/yuki-kimoto/DBIx-Custom>

=head1 AUTHOR

Yuki Kimoto, C<< <kimoto.yuki at gmail.com> >>

=head1 COPYRIGHT & LICENSE

Copyright 2009-2011 Yuki Kimoto, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut


