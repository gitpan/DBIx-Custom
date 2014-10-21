package DBIx::Custom;

our $VERSION = '0.1681';

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
use DBIx::Custom::Util qw/_array_to_hash _subname/;
use Encode qw/encode_utf8 decode_utf8/;

use constant DEBUG => $ENV{DBIX_CUSTOM_DEBUG} || 0;

our @COMMON_ARGS = qw/table query filter type/;

__PACKAGE__->attr(
    [qw/connector data_source password pid user/],
    cache => 0,
    cache_method => sub {
        sub {
            my $self = shift;
            
            $self->{_cached} ||= {};
            
            if (@_ > 1) {
                $self->{_cached}{$_[0]} = $_[1];
            }
            else {
                return $self->{_cached}{$_[0]};
            }
        }
    },
    dbi_option => sub { {} },
    default_dbi_option => sub {
        {
            RaiseError => 1,
            PrintError => 0,
            AutoCommit => 1
        }
    },
    filters => sub {
        {
            encode_utf8 => sub { encode_utf8($_[0]) },
            decode_utf8 => sub { decode_utf8($_[0]) }
        }
    },
    models => sub { {} },
    query_builder => sub { DBIx::Custom::QueryBuilder->new },
    result_class  => 'DBIx::Custom::Result',
    reserved_word_quote => '',
    safety_character => '\w',
    stash => sub { {} }
);

our $AUTOLOAD;
sub AUTOLOAD {
    my $self = shift;

    # Method name
    my ($package, $mname) = $AUTOLOAD =~ /^([\w\:]+)\:\:(\w+)$/;

    # Call method
    $self->{_methods} ||= {};
    if (my $method = $self->{_methods}->{$mname}) {
        return $self->$method(@_)
    }
    elsif ($self->{dbh} && (my $dbh_method = $self->dbh->can($mname))) {
        $self->dbh->$dbh_method(@_);
    }
    else {
        croak qq{Can't locate object method "$mname" via "$package" }
            . _subname;
    }
}

sub apply_filter {
    my ($self, $table, @cinfos) = @_;

    # Initialize filters
    $self->{filter} ||= {};
    $self->{filter}{out} ||= {};
    $self->{filter}{in} ||= {};
    $self->{filter}{end} ||= {};
    
    # Usage
    my $usage = "Usage: \$dbi->apply_filter(" .
                "TABLE, COLUMN1, {in => INFILTER1, out => OUTFILTER1, end => ENDFILTER1}, " .
                "COLUMN2, {in => INFILTER2, out => OUTFILTER2, end => ENDFILTER2}, ...)";
    
    # Apply filter
    for (my $i = 0; $i < @cinfos; $i += 2) {
        
        # Column
        my $column = $cinfos[$i];
        if (ref $column eq 'ARRAY') {
            foreach my $c (@$column) {
                push @cinfos, $c, $cinfos[$i + 1];
            }
            next;
        }
        
        # Filter infomation
        my $finfo = $cinfos[$i + 1] || {};
        croak "$usage (table: $table) " . _subname
          unless  ref $finfo eq 'HASH';
        foreach my $ftype (keys %$finfo) {
            croak "$usage (table: $table) " . _subname
              unless $ftype eq 'in' || $ftype eq 'out' || $ftype eq 'end'; 
        }
        
        # Set filters
        foreach my $way (qw/in out end/) {
        
            # Filter
            my $filter = $finfo->{$way};
            
            # Filter state
            my $state = !exists $finfo->{$way} ? 'not_exists'
                      : !defined $filter        ? 'not_defined'
                      : ref $filter eq 'CODE'   ? 'code'
                      : 'name';
            
            # Filter is not exists
            next if $state eq 'not_exists';
            
            # Check filter name
            croak qq{Filter "$filter" is not registered } . _subname
              if  $state eq 'name'
               && ! exists $self->filters->{$filter};
            
            # Set filter
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


sub assign_tag {
    my ($self, $param) = @_;
    
    # Create set tag
    my @params;
    my $safety = $self->safety_character;
    my $q = $self->reserved_word_quote;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name } . _subname
          unless $column =~ /^[$safety\.]+$/;
        my $column = "$q$column$q";
        $column =~ s/\./$q.$q/;
        push @params, "$column = {? $column}";
    }
    my $tag = join(', ', @params);
    
    return $tag;
}

sub column {
    my ($self, $table, $columns) = @_;
    
    # Reserved word quote
    my $q = $self->reserved_word_quote;
    
    # Column clause
    my @column;
    $columns ||= [];
    push @column, "$q$table$q.$q$_$q as $q${table}${q}__$q$_$q" for @$columns;
    
    return join (', ', @column);
}

sub connect {
    my $self = ref $_[0] ? shift : shift->new(@_);;
    
    # Connect
    $self->dbh;
    
    # Set process ID
    $self->pid($$);
    
    return $self;
}

sub create_query {
    my ($self, $source) = @_;
    
    # Cache
    my $cache = $self->cache;
    
    # Query
    my $query;
    
    # Get cached query
    if ($cache) {
        
        # Get query
        my $q = $self->cache_method->($self, $source);
        
        # Create query
        if ($q) {
            $query = DBIx::Custom::Query->new($q);
            $query->filters($self->filters);
        }
    }
    
    # Create query
    unless ($query) {

        # Create query
        my $builder = $self->query_builder;
        $query = $builder->build_query($source);

        # Remove reserved word quote
        if (my $q = $self->reserved_word_quote) {
            $_ =~ s/$q//g for @{$query->columns}
        }

        # Save query to cache
        $self->cache_method->(
            $self, $source,
            {
                sql     => $query->sql, 
                columns => $query->columns,
                tables  => $query->tables
            }
        ) if $cache;
    }
    
    # Prepare statement handle
    my $sth;
    eval { $sth = $self->dbh->prepare($query->{sql})};
    
    if ($@) {
        $self->_croak($@, qq{. Following SQL is executed.\n}
                        . qq{$query->{sql}\n} . _subname);
    }
    
    # Set statement handle
    $query->sth($sth);
    
    # Set filters
    $query->filters($self->filters);
    
    return $query;
}

sub dbh {
    my $self = shift;
    
    # Set
    if (@_) {
        $self->{dbh} = $_[0];
        
        return $self;
    }
    
    # Get
    else {
        # From Connction manager
        if (my $connector = $self->connector) {
            croak "connector must have dbh() method " . _subname
              unless ref $connector && $connector->can('dbh');
              
            return $self->{dbh} = $connector->dbh;
        }
        
        return $self->{dbh} ||= $self->_connect;
    }
}

our %DELETE_ARGS
  = map { $_ => 1 } @COMMON_ARGS, qw/where append allow_delete_all where_param/;

sub delete {
    my ($self, %args) = @_;

    # Check arguments
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $DELETE_ARGS{$name};
    }
    
    # Arguments
    my $table = $args{table} || '';
    croak qq{"table" option must be specified. } . _subname
      unless $table;
    my $where            = delete $args{where} || {};
    my $append           = delete $args{append};
    my $allow_delete_all = delete $args{allow_delete_all};
    my $query_return     = delete $args{query};
    my $where_param      = delete $args{where_param} || {};

    # Where
    my $where_clause = '';
    if (ref $where) {
        $where = $self->_where_to_obj($where);
        $where_param = keys %$where_param
                     ? $self->merge_param($where_param, $where->param)
                     : $where->param;
        
        # String where
        $where_clause = $where->to_string;
    }
    elsif ($where) { $where_clause = "where $where" }
    croak qq{"where" must be specified } . _subname
      if $where_clause eq '' && !$allow_delete_all;

    # Delete statement
    my @sql;
    my $q = $self->reserved_word_quote;
    push @sql, "delete from $q$table$q $where_clause";
    push @sql, $append if $append;
    my $sql = join(' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $query_return;
    
    # Execute query
    return $self->execute(
        $query,
        param => $where_param,
        table => $table,
        %args
    );
}

sub delete_all { shift->delete(allow_delete_all => 1, @_) }

our %DELETE_AT_ARGS = (%DELETE_ARGS, where => 1, primary_key => 1);

sub delete_at {
    my ($self, %args) = @_;
    
    # Arguments
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    my $where = delete $args{where};
    
    # Check arguments
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $DELETE_AT_ARGS{$name};
    }
    
    # Create where parameter
    my $where_param = $self->_create_where_param($where, $primary_keys);
    
    return $self->delete(where => $where_param, %args);
}

sub DESTROY { }

sub create_model {
    my $self = shift;
    
    # Arguments
    my $args = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $args->{dbi} = $self;
    my $model_class = delete $args->{model_class} || 'DBIx::Custom::Model';
    my $model_name  = delete $args->{name};
    my $model_table = delete $args->{table};
    $model_name ||= $model_table;
    
    # Create model
    my $model = $model_class->new($args);
    $model->name($model_name) unless $model->name;
    $model->table($model_table) unless $model->table;
    
    # Apply filter
    my $filter = ref $model->filter eq 'HASH'
               ? [%{$model->filter}]
               : $model->filter;
    $self->apply_filter($model->table, @$filter);
    
    # Associate table with model
    croak "Table name is duplicated " . _subname
      if exists $self->{_model_from}->{$model->table};
    $self->{_model_from}->{$model->table} = $model->name;

    # Table alias
    $self->{_table_alias} ||= {};
    $self->{_table_alias} = {%{$self->{_table_alias}}, %{$model->table_alias}};
    
    # Set model
    $self->model($model->name, $model);
    
    return $self->model($model->name);
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

our %EXECUTE_ARGS = map { $_ => 1 } @COMMON_ARGS, 'param';

sub execute {
    my ($self, $query, %args)  = @_;
    
    # Arguments
    my $param  = delete $args{param} || {};
    my $tables = delete $args{table} || [];
    $tables = [$tables] unless ref $tables eq 'ARRAY';
    my $filter = delete $args{filter};
    $filter = _array_to_hash($filter);
    my $type = delete $args{type};
    $type = _array_to_hash($type);
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $EXECUTE_ARGS{$name};
    }
    
    # Create query
    $query = $self->create_query($query) unless ref $query;
    $filter ||= $query->filter;
    
    # Tables
    unshift @$tables, @{$query->tables};
    my $main_table = pop @$tables;
    $tables = $self->_remove_duplicate_table($tables, $main_table);
    if (my $q = $self->reserved_word_quote) {
        $_ =~ s/$q//g for @$tables;
    }
    
    # Table alias
    foreach my $table (@$tables) {
        
        # No need
        next unless my $alias = $self->{_table_alias}->{$table};
        $self->{filter} ||= {};
        next if $self->{filter}{out}{$table};
        
        # Filter
        $self->{filter}{out} ||= {};
        $self->{filter}{in}  ||= {};
        $self->{filter}{end} ||= {};
        
        # Create alias filter
        foreach my $type (qw/out in end/) {
            my @filter_names = keys %{$self->{filter}{$type}{$alias} || {}};
            foreach my $filter_name (@filter_names) {
                my $filter_name_alias = $filter_name;
                $filter_name_alias =~ s/^$alias\./$table\./;
                $filter_name_alias =~ s/^${alias}__/${table}__/; 
                $self->{filter}{$type}{$table}{$filter_name_alias}
                  = $self->{filter}{$type}{$alias}{$filter_name}
            }
        }
    }
    
    # Applied filter
    my $applied_filter = {};
    foreach my $table (@$tables) {
        $applied_filter = {
            %$applied_filter,
            %{$self->{filter}{out}->{$table} || {}}
        }
    }
    $filter = {%$applied_filter, %$filter};
    
    # Replace filter name to code
    foreach my $column (keys %$filter) {
        my $name = $filter->{$column};
        if (!defined $name) {
            $filter->{$column} = undef;
        }
        elsif (ref $name ne 'CODE') {
          croak qq{Filter "$name" is not registered" } . _subname
            unless exists $self->filters->{$name};
          $filter->{$column} = $self->filters->{$name};
        }
    }
    
    # Create bind values
    my $bind = $self->_create_bind_values(
        $param,
        $query->columns,
        $filter,
        $type
    );
    
    # Execute
    my $sth = $query->sth;
    my $affected;
    eval {
        for (my $i = 0; $i < @$bind; $i++) {
            my $type = $bind->[$i]->{type};
            $sth->bind_param($i + 1, $bind->[$i]->{value}, $type ? $type : ());
        }
        $affected = $sth->execute;
    };
    
    if ($@) {
        $self->_croak($@, qq{. Following SQL is executed.\n}
                        . qq{$query->{sql}\n} . _subname);
    }
    
    # Output SQL for debug
    warn $query->sql . "\n" if DEBUG;
    
    # Select statement
    if ($sth->{NUM_OF_FIELDS}) {
        
        # Filter
        my $filter = {};
        $filter->{in}  = {};
        $filter->{end} = {};
        foreach my $table (@$tables) {
            foreach my $way (qw/in end/) {
                $filter->{$way} = {
                    %{$filter->{$way}},
                    %{$self->{filter}{$way}{$table} || {}}
                };
            }
        }
        
        # Result
        my $result = $self->result_class->new(
            sth            => $sth,
            filters        => $self->filters,
            filter_check   => $self->filter_check,
            default_filter => $self->{default_in_filter},
            filter         => $filter->{in} || {},
            end_filter     => $filter->{end} || {}
        );

        return $result;
    }
    
    # Not select statement
    else { return $affected }
}

our %INSERT_ARGS = map { $_ => 1 } @COMMON_ARGS, qw/param append/;

sub insert {
    my ($self, %args) = @_;
    
    # Arguments
    my $table  = delete $args{table};
    croak qq{"table" option must be specified } . _subname
      unless $table;
    my $param  = delete $args{param} || {};
    my $append = delete $args{append} || '';
    my $query_return  = delete $args{query};

    # Check arguments
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $INSERT_ARGS{$name};
    }

    # Reserved word quote
    my $q = $self->reserved_word_quote;
    
    # Columns
    my @columns;
    my $safety = $self->safety_character;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name } . _subname
          unless $column =~ /^[$safety\.]+$/;
          $column = "$q$column$q";
          $column =~ s/\./$q.$q/;
        push @columns, $column;
    }
    
    # Insert statement
    my @sql;
    push @sql, "insert into $q$table$q {insert_param ". join(' ', @columns) . '}';
    push @sql, $append if $append;
    my $sql = join (' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $query_return;
    
    # Execute query
    return $self->execute(
        $query,
        param => $param,
        table => $table,
        %args
    );
}

our %INSERT_AT_ARGS = (%INSERT_ARGS, where => 1, primary_key => 1);

sub insert_at {
    my ($self, %args) = @_;

    # Arguments
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    my $where = delete $args{where};
    my $param = delete $args{param};
    
    # Check arguments
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $INSERT_AT_ARGS{$name};
    }
    
    # Create where parameter
    my $where_param = $self->_create_where_param($where, $primary_keys);
    $param = $self->merge_param($where_param, $param);
    
    return $self->insert(param => $param, %args);
}

sub insert_param_tag {
    my ($self, $param) = @_;
    
    # Create insert parameter tag
    my $safety = $self->safety_character;
    my $q = $self->reserved_word_quote;
    my @columns;
    my @placeholders;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name } . _subname
          unless $column =~ /^[$safety\.]+$/;
        $column = "$q$column$q";
        $column =~ s/\./$q.$q/;
        push @columns, $column;
        push @placeholders, "{? $column}";
    }
    
    return '(' . join(', ', @columns) . ') ' . 'values ' .
           '(' . join(', ', @placeholders) . ')'
}

sub include_model {
    my ($self, $name_space, $model_infos) = @_;
    
    # Name space
    $name_space ||= '';
    
    # Get Model infomations
    unless ($model_infos) {

        # Load name space module
        croak qq{"$name_space" is invalid class name } . _subname
          if $name_space =~ /[^\w:]/;
        eval "use $name_space";
        croak qq{Name space module "$name_space.pm" is needed. $@ }
            . _subname
          if $@;
        
        # Search model modules
        my $path = $INC{"$name_space.pm"};
        $path =~ s/\.pm$//;
        opendir my $dh, $path
          or croak qq{Can't open directory "$path": $! } . _subname
        $model_infos = [];
        while (my $module = readdir $dh) {
            push @$model_infos, $module
              if $module =~ s/\.pm$//;
        }
        close $dh;
    }
    
    # Include models
    foreach my $model_info (@$model_infos) {
        
        # Load model
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
        else { $model_class = $model_name = $model_table = $model_info }
        my $mclass = "${name_space}::$model_class";
        croak qq{"$mclass" is invalid class name } . _subname
          if $mclass =~ /[^\w:]/;
        unless ($mclass->can('isa')) {
            eval "use $mclass";
            croak "$@ " . _subname if $@;
        }
        
        # Create model
        my $args = {};
        $args->{model_class} = $mclass if $mclass;
        $args->{name}        = $model_name if $model_name;
        $args->{table}       = $model_table if $model_table;
        $self->create_model($args);
    }
    
    return $self;
}

sub merge_param {
    my ($self, @params) = @_;
    
    # Merge parameters
    my $param = {};
    foreach my $p (@params) {
        foreach my $column (keys %$p) {
            if (exists $param->{$column}) {
                $param->{$column} = [$param->{$column}]
                  unless ref $param->{$column} eq 'ARRAY';
                push @{$param->{$column}}, $p->{$column};
            }
            else {
                $param->{$column} = $p->{$column};
            }
        }
    }
    
    return $param;
}

sub method {
    my $self = shift;
    
    # Register method
    my $methods = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $self->{_methods} = {%{$self->{_methods} || {}}, %$methods};
    
    return $self;
}

sub model {
    my ($self, $name, $model) = @_;
    
    # Set model
    if ($model) {
        $self->models->{$name} = $model;
        return $self;
    }
    
    # Check model existance
    croak qq{Model "$name" is not included } . _subname
      unless $self->models->{$name};
    
    # Get model
    return $self->models->{$name};
}

sub mycolumn {
    my ($self, $table, $columns) = @_;
    
    # Create column clause
    my @column;
    my $q = $self->reserved_word_quote;
    $columns ||= [];
    push @column, "$q$table$q.$q$_$q as $q$_$q" for @$columns;
    
    return join (', ', @column);
}

sub new {
    my $self = shift->SUPER::new(@_);
    
    # Check attributes
    my @attrs = keys %$self;
    foreach my $attr (@attrs) {
        croak qq{"$attr" is wrong name } . _subname
          unless $self->can($attr);
    }
    
    # Register tag
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
    my $self = shift;
    
    # Register filter
    my $filters = ref $_[0] eq 'HASH' ? $_[0] : {@_};
    $self->filters({%{$self->filters}, %$filters});
    
    return $self;
}

sub register_tag { shift->query_builder->register_tag(@_) }

our %SELECT_ARGS
  = map { $_ => 1 } @COMMON_ARGS,
                    qw/column where append relation join param where_param wrap/;

sub select {
    my ($self, %args) = @_;

    # Arguments
    my $table = delete $args{table};
    my $tables = ref $table eq 'ARRAY' ? $table
               : defined $table ? [$table]
               : [];
    my $columns   = delete $args{column};
    my $where     = delete $args{where} || {};
    my $append    = delete $args{append};
    my $join      = delete $args{join} || [];
    croak qq{"join" must be array reference } . _subname
      unless ref $join eq 'ARRAY';
    my $relation = delete $args{relation};
    my $param = delete $args{param} || {}; # DEPRECATED!
    warn "DEPRECATED select() param option. this is renamed to where_param"
      if keys %$param;
    my $where_param = delete $args{where_param} || $param || {};
    my $query_return = $args{query};
    my $wrap = delete $args{wrap};

    # Check arguments
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $SELECT_ARGS{$name};
    }
    
    # Add relation tables(DEPRECATED!);
    $self->_add_relation_table($tables, $relation);
    
    # Select statement
    my @sql;
    push @sql, 'select';
    
    # Column clause
    if ($columns) {
        $columns = [$columns] if ! ref $columns;
        foreach my $column (@$columns) {
            unshift @$tables, @{$self->_search_tables($column)};
            push @sql, ($column, ',');
        }
        pop @sql if $sql[-1] eq ',';
    }
    else { push @sql, '*' }
    
    # Table
    push @sql, 'from';
    my $q = $self->reserved_word_quote;
    if ($relation) {
        my $found = {};
        foreach my $table (@$tables) {
            push @sql, ("$q$table$q", ',') unless $found->{$table};
            $found->{$table} = 1;
        }
    }
    else {
        my $main_table = $tables->[-1] || '';
        push @sql, "$q$main_table$q";
    }
    pop @sql if ($sql[-1] || '') eq ',';
    croak "Not found table name " . _subname
      unless $tables->[-1];

    # Add tables in parameter
    unshift @$tables,
            @{$self->_search_tables(join(' ', keys %$where_param) || '')};
    
    # Where
    my $where_clause = '';
    if (ref $where) {
        $where = $self->_where_to_obj($where);
        $where_param = keys %$where_param
                     ? $self->merge_param($where_param, $where->param)
                     : $where->param;
        
        # String where
        $where_clause = $where->to_string;
    }
    elsif ($where) { $where_clause = "where $where" }
    
    # Add table names in where clause
    unshift @$tables, @{$self->_search_tables($where_clause)};
    
    # Push join
    $self->_push_join(\@sql, $join, $tables);
    
    # Add where clause
    push @sql, $where_clause;
    
    # Relation(DEPRECATED!);
    $self->_push_relation(\@sql, $tables, $relation, $where_clause eq '' ? 1 : 0);
    
    # Append
    push @sql, $append if $append;
    
    # Wrap
    if ($wrap) {
        croak "wrap option must be array refrence " . _subname
          unless ref $wrap eq 'ARRAY';
        unshift @sql, $wrap->[0];
        push @sql, $wrap->[1];
    }
    
    # SQL
    my $sql = join (' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $query_return;
    
    # Execute query
    my $result = $self->execute(
        $query,
        param => $where_param, 
        table => $tables,
        %args
    );
    
    return $result;
}

our %SELECT_AT_ARGS = (%SELECT_ARGS, where => 1, primary_key => 1);

sub select_at {
    my ($self, %args) = @_;

    # Arguments
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    my $where = delete $args{where};
    my $param = delete $args{param};
    
    # Check arguments
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $SELECT_AT_ARGS{$name};
    }
    
    # Table
    croak qq{"table" option must be specified } . _subname
      unless $args{table};
    my $table = ref $args{table} ? $args{table}->[-1] : $args{table};
    
    # Create where parameter
    my $where_param = $self->_create_where_param($where, $primary_keys);
    
    return $self->select(where => $where_param, %args);
}

sub setup_model {
    my $self = shift;
    
    # Setup model
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

our %UPDATE_ARGS
  = map { $_ => 1 } @COMMON_ARGS, qw/param where append allow_update_all where_param/;

sub update {
    my ($self, %args) = @_;

    # Arguments
    my $table = delete $args{table} || '';
    croak qq{"table" option must be specified } . _subname
      unless $table;
    my $param            = delete $args{param} || {};
    my $where            = delete $args{where} || {};
    my $where_param      = delete $args{where_param} || {};
    my $append           = delete $args{append} || '';
    my $allow_update_all = delete $args{allow_update_all};
    
    # Check argument names
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $UPDATE_ARGS{$name};
    }
    
    # Columns
    my @columns;
    my $safety = $self->safety_character;
    my $q = $self->reserved_word_quote;
    foreach my $column (keys %$param) {
        croak qq{"$column" is not safety column name } . _subname
          unless $column =~ /^[$safety\.]+$/;
          $column = "$q$column$q";
          $column =~ s/\./$q.$q/;
        push @columns, "$column";
    }
        
    # Update clause
    my $update_clause = '{update_param ' . join(' ', @columns) . '}';

    # Where
    my $where_clause = '';
    if (ref $where) {
        $where = $self->_where_to_obj($where);
        $where_param = keys %$where_param
                     ? $self->merge_param($where_param, $where->param)
                     : $where->param;
        
        # String where
        $where_clause = $where->to_string;
    }
    elsif ($where) { $where_clause = "where $where" }
    croak qq{"where" must be specified } . _subname
      if "$where_clause" eq '' && !$allow_update_all;
    
    # Merge param
    $param = $self->merge_param($param, $where_param) if keys %$where_param;
    
    # Update statement
    my @sql;
    push @sql, "update $q$table$q $update_clause $where_clause";
    push @sql, $append if $append;
    
    # SQL
    my $sql = join(' ', @sql);
    
    # Create query
    my $query = $self->create_query($sql);
    return $query if $args{query};
    
    # Execute query
    my $ret_val = $self->execute(
        $query,
        param  => $param, 
        table => $table,
        %args
    );
    
    return $ret_val;
}

sub update_all { shift->update(allow_update_all => 1, @_) };

our %UPDATE_AT_ARGS = (%UPDATE_ARGS, where => 1, primary_key => 1);

sub update_at {
    my ($self, %args) = @_;
    
    # Arguments
    my $primary_keys = delete $args{primary_key};
    $primary_keys = [$primary_keys] unless ref $primary_keys;
    my $where = delete $args{where};
    

    # Check arguments
    foreach my $name (keys %args) {
        croak qq{"$name" is wrong option } . _subname
          unless $UPDATE_AT_ARGS{$name};
    }
    
    # Create where parameter
    my $where_param = $self->_create_where_param($where, $primary_keys);
    
    return $self->update(where => $where_param, %args);
}

sub update_param_tag {
    my ($self, $param, $opt) = @_;
    
    # Create update parameter tag
    my $tag = $self->assign_tag($param);
    $tag = "set $tag" unless $opt->{no_set};

    return $tag;
}

sub where {
    my $self = shift;
    
    # Create where
    return DBIx::Custom::Where->new(
        query_builder => $self->query_builder,
        safety_character => $self->safety_character,
        reserved_word_quote => $self->reserved_word_quote,
        @_
    );
}

sub _create_bind_values {
    my ($self, $params, $columns, $filter, $type) = @_;
    
    # Create bind values
    my $bind = [];
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
        
        # Type
        push @$bind, {
            value => $f ? $f->($value) : $value,
            type => $type->{$column}
        };
        
        # Count up 
        $count->{$column}++;
    }
    
    return $bind;
}

sub _create_where_param {
    my ($self, $where, $primary_keys) = @_;
    
    # Create where parameter
    my $where_param = {};
    if ($where) {
        $where = [$where] unless ref $where;
        croak qq{"where" must be constant value or array reference}
            . " (" . (caller 1)[3] . ")"
          unless !ref $where || ref $where eq 'ARRAY';
        
        croak qq{"where" must contain values same count as primary key}
            . " (" . (caller 1)[3] . ")"
          unless @$primary_keys eq @$where;
        
        for(my $i = 0; $i < @$primary_keys; $i ++) {
           $where_param->{$primary_keys->[$i]} = $where->[$i];
        }
    }
    
    return $where_param;
}

sub _connect {
    my $self = shift;
    
    # Attributes
    my $data_source = $self->data_source;
    croak qq{"data_source" must be specified } . _subname
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
    croak "$@ " . _subname if $@;
    
    return $dbh;
}

sub _croak {
    my ($self, $error, $append) = @_;
    
    # Append
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

sub _need_tables {
    my ($self, $tree, $need_tables, $tables) = @_;
    
    # Get needed tables
    foreach my $table (@$tables) {
        if ($tree->{$table}) {
            $need_tables->{$table} = 1;
            $self->_need_tables($tree, $need_tables, [$tree->{$table}{parent}])
        }
    }
}

sub _push_join {
    my ($self, $sql, $join, $join_tables) = @_;
    
    # No join
    return unless @$join;
    
    # Push join clause
    my $tree = {};
    my $q = $self->reserved_word_quote;
    for (my $i = 0; $i < @$join; $i++) {
        
        # Search table in join clause
        my $join_clause = $join->[$i];
        my $q_re = quotemeta($q);
        my $join_re = $q ? qr/\s$q_re?([^\.\s$q_re]+?)$q_re?\..+?\s$q_re?([^\.\s$q_re]+?)$q_re?\..+?$/
                         : qr/\s([^\.\s]+?)\..+?\s([^\.\s]+?)\..+?$/;
        if ($join_clause =~ $join_re) {
            my $table1 = $1;
            my $table2 = $2;
            croak qq{right side table of "$join_clause" must be unique }
                . _subname
              if exists $tree->{$table2};
            $tree->{$table2}
              = {position => $i, parent => $table1, join => $join_clause};
        }
        else {
            croak qq{join "$join_clause" must be two table name } . _subname
        }
    }
    
    # Search need tables
    my $need_tables = {};
    $self->_need_tables($tree, $need_tables, $join_tables);
    my @need_tables = sort { $tree->{$a}{position} <=> $tree->{$b}{position} } keys %$need_tables;
    
    # Add join clause
    foreach my $need_table (@need_tables) {
        push @$sql, $tree->{$need_table}{join};
    }
}

sub _remove_duplicate_table {
    my ($self, $tables, $main_table) = @_;
    
    # Remove duplicate table
    my %tables = map {defined $_ ? ($_ => 1) : ()} @$tables;
    delete $tables{$main_table} if $main_table;
    
    return [keys %tables, $main_table ? $main_table : ()];
}

sub _search_tables {
    my ($self, $source) = @_;
    
    # Search tables
    my $tables = [];
    my $safety_character = $self->safety_character;
    my $q = $self->reserved_word_quote;
    my $q_re = quotemeta($q);
    my $table_re = $q ? qr/(?:^|[^$safety_character])$q_re?([$safety_character]+)$q_re?\./
                      : qr/(?:^|[^$safety_character])([$safety_character]+)\./;
    while ($source =~ /$table_re/g) {
        push @$tables, $1;
    }
    
    return $tables;
}

sub _where_to_obj {
    my ($self, $where) = @_;
    
    my $obj;
    
    # Hash
    if (ref $where eq 'HASH') {
        my $clause = ['and'];
        my $q = $self->reserved_word_quote;
        foreach my $column (keys %$where) {
            $column = "$q$column$q";
            $column =~ s/\./$q.$q/;
            push @$clause, "{= $column}" for keys %$where;
        }
        $obj = $self->where(clause => $clause, param => $where);
    }
    
    # DBIx::Custom::Where object
    elsif (ref $where eq 'DBIx::Custom::Where') {
        $obj = $where;
    }
    
    # Array(DEPRECATED!)
    elsif (ref $where eq 'ARRAY') {
        warn "\$dbi->select(where => [CLAUSE, PARAMETER]) is DEPRECATED." .
             "use \$dbi->select(where => \$dbi->where(clause => " .
             "CLAUSE, param => PARAMETER));";
        $obj = $self->where(
            clause => $where->[0],
            param  => $where->[1]
        );
    }
    
    # Check where argument
    croak qq{"where" must be hash reference or DBIx::Custom::Where object}
        . qq{or array reference, which contains where clause and paramter}
        . _subname
      unless ref $obj eq 'DBIx::Custom::Where';
    
    return $obj;
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
sub insert_param {
    warn "insert_param is renamed to insert_param_tag."
       . " insert_param is DEPRECATED!";
    return shift->insert_param_tag(@_);
}

# DEPRECATED!
sub register_tag_processor {
    return shift->query_builder->register_tag_processor(@_);
}

# DEPRECATED!
sub update_param {
    warn "update_param is renamed to update_param_tag."
       . " update_param is DEPRECATED!";
    return shift->update_param_tag(@_);
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

=head2 C<connector>

    my $connector = $dbi->connector;
    $dbi          = $dbi->connector(DBIx::Connector->new(...));

Connection manager object. if connector is set, you can get C<dbh()>
from connection manager. conection manager object must have dbh() mehtod.

This is L<DBIx::Connector> example. Please pass
C<default_dbi_option> to L<DBIx::Connector>.

    my $connector = DBIx::Connector->new(
        "dbi:mysql:database=$DATABASE",
        $USER,
        $PASSWORD,
        DBIx::Custom->new->default_dbi_option
    );
    
    my $dbi = DBIx::Custom->new(connector => $connector);

=head2 C<data_source>

    my $data_source = $dbi->data_source;
    $dbi            = $dbi->data_source("DBI:mysql:database=dbname");

Data source, used when C<connect()> is executed.

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

You should not change C<AutoCommit> value directly,
the value is used to check if the process is in transaction.

=head2 C<filters>

    my $filters = $dbi->filters;
    $dbi        = $dbi->filters(\%filters);

Filters, registered by C<register_filter()>.

=head2 C<models>

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

=head2 C<reserved_word_quote>

     my reserved_word_quote = $dbi->reserved_word_quote;
     $dbi                   = $dbi->reserved_word_quote('"');

Reserved word quote, default to empty string.

=head2 C<result_class>

    my $result_class = $dbi->result_class;
    $dbi             = $dbi->result_class('DBIx::Custom::Result');

Result class, default to L<DBIx::Custom::Result>.

=head2 C<safety_character>

    my $safety_character = $self->safety_character;
    $dbi                 = $self->safety_character($character);

Regex of safety character for table and column name, default to '\w'.
Note that you don't have to specify like '[\w]'.

=head2 C<user>

    my $user = $dbi->user;
    $dbi     = $dbi->user('Ken');

User name, used when C<connect()> is executed.

=head1 METHODS

L<DBIx::Custom> inherits all methods from L<Object::Simple>
and use all methods of L<DBI>
and implements the following new ones.

=head2 C<apply_filter>

    $dbi->apply_filter(
        'book',
        'issue_date' => {
            out => 'tp_to_date',
            in  => 'date_to_tp',
            end => 'tp_to_displaydate'
        },
        'write_date' => {
            out => 'tp_to_date',
            in  => 'date_to_tp',
            end => 'tp_to_displaydate'
        }
    );

Apply filter to columns.
C<out> filter is executed before data is send to database.
C<in> filter is executed after a row is fetch.
C<end> filter is execute after C<in> filter is executed.

Filter is applied to the follwoing tree column name pattern.

       PETTERN         EXAMPLE
    1. Column        : author
    2. Table.Column  : book.author
    3. Table__Column : book__author

If column name is duplicate with other table,
Main filter specified by C<table> option is used.

You can set multiple filters at once.

    $dbi->apply_filter(
        'book',
        [qw/issue_date write_date/] => {
            out => 'tp_to_date',
            in  => 'date_to_tp',
            end => 'tp_to_displaydate'
        }
    );

=head2 C<assign_tag> EXPERIMENTAL

    my $assign_tag = $dbi->assign_tag({title => 'a', age => 2});

Create assign tag.

    title = {? title}, author = {? author}

This is equal to C<update_param_tag> exept that set is not added.

=head2 C<connect>

    my $dbi = DBIx::Custom->connect(
        data_source => "dbi:mysql:database=dbname",
        user => 'ken',
        password => '!LFKD%$&',
        dbi_option => {mysql_enable_utf8 => 1}
    );

Connect to the database and create a new L<DBIx::Custom> object.

L<DBIx::Custom> is a wrapper of L<DBI>.
C<AutoCommit> and C<RaiseError> options are true, 
and C<PrintError> option is false by default.

=head2 create_model

    my $model = $dbi->create_model(
        table => 'book',
        primary_key => 'id',
        join => [
            'inner join company on book.comparny_id = company.id'
        ],
        filter => {
            publish_date => {
                out => 'tp_to_date',
                in => 'date_to_tp',
                end => 'tp_to_displaydate'
            }
        }
    );

Create L<DBIx::Custom::Model> object and initialize model.
the module is also used from model() method.

   $dbi->model('book')->select(...);

=head2 C<create_query>
    
    my $query = $dbi->create_query(
        "insert into book {insert_param title author};";
    );

Create L<DBIx::Custom::Query> object.

If you want to get high performance,
create L<DBIx::Custom::Query> object and execute the query by C<execute()>
instead of other methods, such as C<insert>, C<update>.

    $dbi->execute($query, {author => 'Ken', title => '%Perl%'});

=head2 C<dbh>

    my $dbh = $dbi->dbh;

Get L<DBI> database handle. if C<connector> is set, you can get
database handle from C<connector>.

=head2 C<each_column>

    $dbi->each_column(
        sub {
            my ($dbi, $table, $column, $column_info) = @_;
            
            my $type = $column_info->{TYPE_NAME};
            
            if ($type eq 'DATE') {
                # ...
            }
        }
    );

Iterate all column informations of all table from database.
Argument is callback when one column is found.
Callback receive four arguments, dbi object, table name,
column name and column information.

=head2 C<execute>

    my $result = $dbi->execute(
        "select * from book where {= title} and {like author}",
        param => {title => 'Perl', author => '%Ken%'}
    );

Execute SQL, containing tags.
Return value is L<DBIx::Custom::Result> in select statement, or
the count of affected rows in insert, update, delete statement.

Tag is turned into the statement containing place holder
before SQL is executed.

    select * from where title = ? and author like ?;

See also L<Tags/Tags>.

The following opitons are currently available.

=over 4

=item C<table>

Table names for filtering.

    $dbi->execute(table => ['author', 'book']);

C<execute()> is unlike C<insert()>, C<update()>, C<delete()>, C<select(),
Filtering is off because we don't know what filter is applied.






=item C<filter>

Filter, executed before data is send to database. This is array reference.
Filter value is code reference or
filter name registerd by C<register_filter()>.

    # Basic
    $dbi->execute(
        $sql,
        filter => {
            title  => sub { uc $_[0] }
            author => sub { uc $_[0] }
        }
    );
    
    # At once (use array reference)
    $dbi->execute(
        $sql,
        filter => [
            [qw/title author/]  => sub { uc $_[0] }
        ]
    );
    
    # Filter name
    $dbi->execute(
        $sql,
        filter => {
            title  => 'upper_case',
            author => 'upper_case'
        }
    );

These filters are added to the C<out> filters, set by C<apply_filter()>.

=back

=head2 C<delete>

    $dbi->delete(table => 'book', where => {title => 'Perl'});

Delete statement.

The following opitons are currently available.

=over 4

=item C<table>

Table name.

    $dbi->delete(table => 'book');

=item C<where>

Where clause. This is hash reference or L<DBIx::Custom::Where> object
or array refrence, which contains where clause and paramter.
    
    # Hash reference
    $dbi->delete(where => {title => 'Perl'});
    
    # DBIx::Custom::Where object
    my $where = $dbi->where(
        clause => ['and', '{= author}', '{like title}'],
        param  => {author => 'Ken', title => '%Perl%'}
    );
    $dbi->delete(where => $where);

    # String(with where_param option)
    $dbi->delete(
        where => '{like title}',
        where_param => {title => '%Perl%'}
    );
    
=item C<append>

Append statement to last of SQL. This is string.

    $dbi->delete(append => 'order by title');

=item C<filter>

Filter, executed before data is send to database. This is array reference.
Filter value is code reference or
filter name registerd by C<register_filter()>.

    # Basic
    $dbi->delete(
        filter => {
            title  => sub { uc $_[0] }
            author => sub { uc $_[0] }
        }
    );
    
    # At once (use array reference)
    $dbi->delete(
        filter => [
            [qw/title author/]  => sub { uc $_[0] }
        ]
    );
    
    # Filter name
    $dbi->delete(
        filter => {
            title  => 'upper_case',
            author => 'upper_case'
        }
    );

These filters are added to the C<out> filters, set by C<apply_filter()>.

=head2 C<column>

    my $column = $self->column(book => ['author', 'title']);

Create column clause. The follwoing column clause is created.

    book.author as book__author,
    book.title as book__title

=item C<query>

Get L<DBIx::Custom::Query> object instead of executing SQL.
This is true or false value.

    my $query = $dbi->delete(query => 1);

You can check SQL.

    my $sql = $query->sql;

=back

=head2 C<delete_all>

    $dbi->delete_all(table => $table);

Delete statement to delete all rows.
Options is same as C<delete()>.

=head2 C<delete_at()>

Delete statement, using primary key.

    $dbi->delete_at(
        table => 'book',
        primary_key => 'id',
        where => '5'
    );

This method is same as C<delete()> exept that
C<primary_key> is specified and C<where> is constant value or array refrence.
all option of C<delete()> is available.

=over 4

=item C<primary_key>

Primary key. This is constant value or array reference.
    
    # Constant value
    $dbi->delete(primary_key => 'id');

    # Array reference
    $dbi->delete(primary_key => ['id1', 'id2' ]);

This is used to create where clause.

=item C<where>

Where clause, created from primary key information.
This is constant value or array reference.

    # Constant value
    $dbi->delete(where => 5);

    # Array reference
    $dbi->delete(where => [3, 5]);

In first examle, the following SQL is created.

    delete from book where id = ?;

Place holder is set to 5.

=back

=head2 C<insert>

    $dbi->insert(
        table  => 'book', 
        param  => {title => 'Perl', author => 'Ken'}
    );

Insert statement.

The following opitons are currently available.

=over 4

=item C<table>

Table name.

    $dbi->insert(table => 'book');

=item C<param>

Insert data. This is hash reference.

    $dbi->insert(param => {title => 'Perl'});

=item C<append>

Append statement to last of SQL. This is string.

    $dbi->insert(append => 'order by title');

=item C<filter>

Filter, executed before data is send to database. This is array reference.
Filter value is code reference or
filter name registerd by C<register_filter()>.

    # Basic
    $dbi->insert(
        filter => {
            title  => sub { uc $_[0] }
            author => sub { uc $_[0] }
        }
    );
    
    # At once (use array reference)
    $dbi->insert(
        filter => [
            [qw/title author/]  => sub { uc $_[0] }
        ]
    );
    
    # Filter name
    $dbi->insert(
        filter => {
            title  => 'upper_case',
            author => 'upper_case'
        }
    );

These filters are added to the C<out> filters, set by C<apply_filter()>.

=item C<query>

Get L<DBIx::Custom::Query> object instead of executing SQL.
This is true or false value.

    my $query = $dbi->insert(query => 1);

You can check SQL.

    my $sql = $query->sql;

=back

=head2 C<insert_at()>

Insert statement, using primary key.

    $dbi->insert_at(
        table => 'book',
        primary_key => 'id',
        where => '5',
        param => {title => 'Perl'}
    );

This method is same as C<insert()> exept that
C<primary_key> is specified and C<where> is constant value or array refrence.
all option of C<insert()> is available.

=over 4

=item C<primary_key>

Primary key. This is constant value or array reference.
    
    # Constant value
    $dbi->insert(primary_key => 'id');

    # Array reference
    $dbi->insert(primary_key => ['id1', 'id2' ]);

This is used to create parts of insert data.

=item C<where>

Parts of Insert data, create from primary key information.
This is constant value or array reference.

    # Constant value
    $dbi->insert(where => 5);

    # Array reference
    $dbi->insert(where => [3, 5]);

In first examle, the following SQL is created.

    insert into book (id, title) values (?, ?);

Place holders are set to 5 and 'Perl'.

=back

=head2 C<insert_param_tag>

    my $insert_param_tag = $dbi->insert_param_tag({title => 'a', age => 2});

Create insert parameter tag.

    (title, author) values ({? title}, {? author});

=head2 C<include_model>

    $dbi->include_model('MyModel');

Include models from specified namespace,
the following layout is needed to include models.

    lib / MyModel.pm
        / MyModel / book.pm
                  / company.pm

Name space module, extending L<DBIx::Custom::Model>.

B<MyModel.pm>

    package MyModel;
    
    use base 'DBIx::Custom::Model';
    
    1;

Model modules, extending name space module.

B<MyModel/book.pm>

    package MyModel::book;
    
    use base 'MyModel';
    
    1;

B<MyModel/company.pm>

    package MyModel::company;
    
    use base 'MyModel';
    
    1;
    
MyModel::book and MyModel::company is included by C<include_model()>.

You can get model object by C<model()>.

    my $book_model    = $dbi->model('book');
    my $company_model = $dbi->model('company');

See L<DBIx::Custom::Model> to know model features.

=head2 C<merge_param>

    my $param = $dbi->merge_param({key1 => 1}, {key1 => 1, key2 => 2});

Merge paramters.

$param:

    {key1 => [1, 1], key2 => 2}

=head2 C<method>

    $dbi->method(
        update_or_insert => sub {
            my $self = shift;
            
            # Process
        },
        find_or_create   => sub {
            my $self = shift;
            
            # Process
        }
    );

Register method. These method is called directly from L<DBIx::Custom> object.

    $dbi->update_or_insert;
    $dbi->find_or_create;

=head2 C<model>

    $dbi->model('book')->method(
        insert => sub { ... },
        update => sub { ... }
    );
    
    my $model = $dbi->model('book');

Set and get a L<DBIx::Custom::Model> object,

=head2 C<mycolumn>

    my $column = $self->mycolumn(book => ['author', 'title']);

Create column clause for myself. The follwoing column clause is created.

    book.author as author,
    book.title as title

=head2 C<new>

    my $dbi = DBIx::Custom->new(
        data_source => "dbi:mysql:database=dbname",
        user => 'ken',
        password => '!LFKD%$&',
        dbi_option => {mysql_enable_utf8 => 1}
    );

Create a new L<DBIx::Custom> object.

=head2 C<not_exists>

    my $not_exists = $dbi->not_exists;

DBIx::Custom::NotExists object, indicating the column is not exists.
This is used by C<clause> of L<DBIx::Custom::Where> .

=head2 C<register_filter>

    $dbi->register_filter(
        # Time::Piece object to database DATE format
        tp_to_date => sub {
            my $tp = shift;
            return $tp->strftime('%Y-%m-%d');
        },
        # database DATE format to Time::Piece object
        date_to_tp => sub {
           my $date = shift;
           return Time::Piece->strptime($date, '%Y-%m-%d');
        }
    );
    
Register filters, used by C<filter> option of many methods.

=head2 C<register_tag>

    $dbi->register_tag(
        update => sub {
            my @columns = @_;
            
            # Update parameters
            my $s = 'set ';
            $s .= "$_ = ?, " for @columns;
            $s =~ s/, $//;
            
            return [$s, \@columns];
        }
    );

Register tag, used by C<execute()>.

See also L<Tags/Tags> about tag registered by default.

Tag parser receive arguments specified in tag.
In the following tag, 'title' and 'author' is parser arguments

    {update_param title author} 

Tag parser must return array refrence,
first element is the result statement, 
second element is column names corresponding to place holders.

In this example, result statement is 

    set title = ?, author = ?

Column names is

    ['title', 'author']

=head2 C<select>

    my $result = $dbi->select(
        table  => 'book',
        column => ['author', 'title'],
        where  => {author => 'Ken'},
    );
    
Select statement.

The following opitons are currently available.

=over 4

=item C<table>

Table name.

    $dbi->select(table => 'book');

=item C<column>

Column clause. This is array reference or constant value.

    # Hash refernce
    $dbi->select(column => ['author', 'title']);
    
    # Constant value
    $dbi->select(column => 'author');

Default is '*' unless C<column> is specified.

    # Default
    $dbi->select(column => '*');

=item C<where>

Where clause. This is hash reference or L<DBIx::Custom::Where> object,
or array refrence, which contains where clause and paramter.
    
    # Hash reference
    $dbi->select(where => {author => 'Ken', 'title' => 'Perl'});
    
    # DBIx::Custom::Where object
    my $where = $dbi->where(
        clause => ['and', '{= author}', '{like title}'],
        param  => {author => 'Ken', title => '%Perl%'}
    );
    $dbi->select(where => $where);

    # String(with where_param option)
    $dbi->select(
        where => '{like title}',
        where_param => {title => '%Perl%'}
    );
    
=item C<join>

Join clause used in need. This is array reference.

    $dbi->select(join =>
        [
            'left outer join company on book.company_id = company_id',
            'left outer join location on company.location_id = location.id'
        ]
    );

If column cluase or where clause contain table name like "company.name",
needed join clause is used automatically.

    $dbi->select(
        table => 'book',
        column => ['company.location_id as company__location_id'],
        where => {'company.name' => 'Orange'},
        join => [
            'left outer join company on book.company_id = company.id',
            'left outer join location on company.location_id = location.id'
        ]
    );

In above select, the following SQL is created.

    select company.location_id as company__location_id
    from book
      left outer join company on book.company_id = company.id
    where company.name = Orange

=item C<param> EXPERIMETNAL

Parameter shown before where clause.
    
    $dbi->select(
        table => 'table1',
        column => 'table1.key1 as table1_key1, key2, key3',
        where   => {'table1.key2' => 3},
        join  => ['inner join (select * from table2 where {= table2.key3})' . 
                  ' as table2 on table1.key1 = table2.key1'],
        param => {'table2.key3' => 5}
    );

For example, if you want to contain tag in join clause, 
you can pass parameter by C<param> option.

=item C<append>

Append statement to last of SQL. This is string.

    $dbi->select(append => 'order by title');

=item C<wrap> EXPERIMENTAL

Wrap statement. This is array reference.

    $dbi->select(wrap => ['select * from (', ') as t where ROWNUM < 10']);

This option is for Oracle and SQL Server paging process.

=item C<filter>

Filter, executed before data is send to database. This is array reference.
Filter value is code reference or
filter name registerd by C<register_filter()>.

    # Basic
    $dbi->select(
        filter => {
            title  => sub { uc $_[0] }
            author => sub { uc $_[0] }
        }
    );
    
    # At once (use array reference)
    $dbi->select(
        filter => [
            [qw/title author/]  => sub { uc $_[0] }
        ]
    );
    
    # Filter name
    $dbi->select(
        filter => {
            title  => 'upper_case',
            author => 'upper_case'
        }
    );

These filters are added to the C<out> filters, set by C<apply_filter()>.

=item C<query>

Get L<DBIx::Custom::Query> object instead of executing SQL.
This is true or false value.

    my $query = $dbi->select(query => 1);

You can check SQL.

    my $sql = $query->sql;

=item C<type>

Specify database data type.

    $dbi->select(type => [image => DBI::SQL_BLOB]);
    $dbi->select(type => [[qw/image audio/] => DBI::SQL_BLOB]);

This is used to bind paramter by C<bind_param()> of statment handle.

    $sth->bind_param($pos, $value, DBI::SQL_BLOB);

=back

=head2 C<select_at()>

Select statement, using primary key.

    $dbi->select_at(
        table => 'book',
        primary_key => 'id',
        where => '5'
    );

This method is same as C<select()> exept that
C<primary_key> is specified and C<where> is constant value or array refrence.
all option of C<select()> is available.

=over 4

=item C<primary_key>

Primary key. This is constant value or array reference.
    
    # Constant value
    $dbi->select(primary_key => 'id');

    # Array reference
    $dbi->select(primary_key => ['id1', 'id2' ]);

This is used to create where clause.

=item C<where>

Where clause, created from primary key information.
This is constant value or array reference.

    # Constant value
    $dbi->select(where => 5);

    # Array reference
    $dbi->select(where => [3, 5]);

In first examle, the following SQL is created.

    select * from book where id = ?

Place holder is set to 5.

=back

=head2 C<update>

    $dbi->update(
        table  => 'book',
        param  => {title => 'Perl'},
        where  => {id => 4}
    );

Update statement.

The following opitons are currently available.

=over 4

=item C<table>

Table name.

    $dbi->update(table => 'book');

=item C<param>

Update data. This is hash reference.

    $dbi->update(param => {title => 'Perl'});

=item C<where>

Where clause. This is hash reference or L<DBIx::Custom::Where> object
or array refrence.
    
    # Hash reference
    $dbi->update(where => {author => 'Ken', 'title' => 'Perl'});
    
    # DBIx::Custom::Where object
    my $where = $dbi->where(
        clause => ['and', '{= author}', '{like title}'],
        param  => {author => 'Ken', title => '%Perl%'}
    );
    $dbi->update(where => $where);
    
    # String(with where_param option)
    $dbi->update(
        param => {title => 'Perl'},
        where => '{= id}',
        where_param => {id => 2}
    );
    
=item C<append>

Append statement to last of SQL. This is string.

    $dbi->update(append => 'order by title');

=item C<filter>

Filter, executed before data is send to database. This is array reference.
Filter value is code reference or
filter name registerd by C<register_filter()>.

    # Basic
    $dbi->update(
        filter => {
            title  => sub { uc $_[0] }
            author => sub { uc $_[0] }
        }
    );
    
    # At once (use array reference)
    $dbi->update(
        filter => [
            [qw/title author/]  => sub { uc $_[0] }
        ]
    );
    
    # Filter name
    $dbi->update(
        filter => {
            title  => 'upper_case',
            author => 'upper_case'
        }
    );

These filters are added to the C<out> filters, set by C<apply_filter()>.

=item C<query>

Get L<DBIx::Custom::Query> object instead of executing SQL.
This is true or false value.

    my $query = $dbi->update(query => 1);

You can check SQL.

    my $sql = $query->sql;

=back

=head2 C<update_all>

    $dbi->update_all(table => 'book', param => {title => 'Perl'});

Update statement to update all rows.
Options is same as C<update()>.

=head2 C<update_at()>

Update statement, using primary key.

    $dbi->update_at(
        table => 'book',
        primary_key => 'id',
        where => '5',
        param => {title => 'Perl'}
    );

This method is same as C<update()> exept that
C<primary_key> is specified and C<where> is constant value or array refrence.
all option of C<update()> is available.

=over 4

=item C<primary_key>

Primary key. This is constant value or array reference.
    
    # Constant value
    $dbi->update(primary_key => 'id');

    # Array reference
    $dbi->update(primary_key => ['id1', 'id2' ]);

This is used to create where clause.

=item C<where>

Where clause, created from primary key information.
This is constant value or array reference.

    # Constant value
    $dbi->update(where => 5);

    # Array reference
    $dbi->update(where => [3, 5]);

In first examle, the following SQL is created.

    update book set title = ? where id = ?

Place holders are set to 'Perl' and 5.

=back

=head2 C<update_param_tag>

    my $update_param_tag = $dbi->update_param_tag({title => 'a', age => 2});

Create update parameter tag.

    set title = {? title}, author = {? author}

You can create tag without 'set '
by C<no_set> option.

    my $update_param_tag = $dbi->update_param_tag(
        {title => 'a', age => 2}
        {no_set => 1}
    );

    title = {? title}, author = {? author}

=head2 C<where>

    my $where = $dbi->where(
        clause => ['and', '{= title}', '{= author}'],
        param => {title => 'Perl', author => 'Ken'}
    );

Create a new L<DBIx::Custom::Where> object.

=head2 C<setup_model>

    $dbi->setup_model;

Setup all model objects.
C<columns> of model object is automatically set, parsing database information.

=head1 Tags

The following tags is available.

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

=head1 ENVIRONMENT VARIABLE

=head2 C<DBIX_CUSTOM_DEBUG>

If environment variable C<DBIX_CUSTOM_DEBUG> is set to true,
executed SQL is printed to STDERR.

=head1 STABILITY

L<DBIx::Custom> is stable. APIs keep backword compatible
except EXPERIMENTAL one in the feature.

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


