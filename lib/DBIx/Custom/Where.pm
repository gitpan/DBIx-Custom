package DBIx::Custom::Where;

use Object::Simple -base;

use overload 'bool' => sub {1}, fallback => 1;
use overload '""' => sub { shift->to_string }, fallback => 1;

use DBIx::Custom::Util '_subname';
use Carp 'croak';

# Carp trust relationship
push @DBIx::Custom::CARP_NOT, __PACKAGE__;

has [qw/param query_builder safety_character/],
    clause => sub { [] },
    reserved_word_quote => '';

sub new {
    my $self = shift->SUPER::new(@_);
    
    # Check attribute names
    my @attrs = keys %$self;
    foreach my $attr (@attrs) {
        croak qq{"$attr" is invalid attribute name (} . _subname . ")"
          unless $self->can($attr);
    }
    
    return $self;
}

sub to_string {
    my $self = shift;
    
    # Check if column name is safety character;
    my $safety = $self->safety_character;
    if (ref $self->param eq 'HASH') {
        foreach my $column (keys %{$self->param}) {
            croak qq{"$column" is not safety column name (} . _subname . ")"
              unless $column =~ /^[$safety\.]+$/;
        }
    }
    # Clause
    my $clause = $self->clause;
    $clause = ['and', $clause] unless ref $clause eq 'ARRAY';
    $clause->[0] = 'and' unless @$clause;

    # Parse
    my $where = [];
    my $count = {};
    $self->_parse($clause, $where, $count, 'and');
    
    # Stringify
    unshift @$where, 'where' if @$where;
    return join(' ', @$where);
}

our %VALID_OPERATIONS = map { $_ => 1 } qw/and or/;
sub _parse {
    my ($self, $clause, $where, $count, $op) = @_;
    
    # Array
    if (ref $clause eq 'ARRAY') {
        
        # Start
        push @$where, '(';
        
        # Operation
        my $op = $clause->[0] || '';
        croak qq{First argument must be "and" or "or" in where clause } .
              qq{"$op" is passed} . _subname . ")"
          unless $VALID_OPERATIONS{$op};
        
        # Parse internal clause
        for (my $i = 1; $i < @$clause; $i++) {
            my $pushed = $self->_parse($clause->[$i], $where, $count, $op);
            push @$where, $op if $pushed;
        }
        pop @$where if $where->[-1] eq $op;
        
        # Undo
        if ($where->[-1] eq '(') {
            pop @$where;
            pop @$where;
        }
        # End
        else { push @$where, ')' }
    }
    
    # String
    else {
        # Pushed
        my $pushed;
        
        # Column
        my $columns = $self->query_builder->build_query($clause)->columns;
        if (@$columns == 0) {
            push @$where, $clause;
            $pushed = 1;
            return $pushed;
        }
        elsif (@$columns != 1) {
            croak qq{Each part contains one column name: "$clause" (}
                  . _subname . ")";
        }

        my $column = $columns->[0];
        if (my $q = $self->reserved_word_quote) {
            $column =~ s/$q//g;
        }
        
        my $safety = $self->safety_character;
        croak qq{"$column" is not safety column name (} . _subname . ")"
          unless $column =~ /^[$safety\.]+$/;
        
        # Column count up
        my $count = ++$count->{$column};
        
        # Push
        my $param = $self->param;
        if (ref $param eq 'HASH') {
            if (exists $param->{$column}) {
                if (ref $param->{$column} eq 'ARRAY') {
                    $pushed = 1
                      if  exists $param->{$column}->[$count - 1]
                       && ref $param->{$column}->[$count - 1] ne 'DBIx::Custom::NotExists';
                } 
                elsif ($count == 1) {
                    $pushed = 1;
                }
            }
            push @$where, $clause if $pushed;
        }
        elsif (!defined $param) {
            push @$where, $clause;
            $pushed = 1;
        }
        else {
            croak "Parameter must be hash reference or undfined value ("
                . _subname . ")"
        }
        return $pushed;
    }
}

1;

=head1 NAME

DBIx::Custom::Where - Where clause

=head1 SYNOPSYS

    my $where = DBIx::Custom::Where->new;

=head1 ATTRIBUTES

=head2 C<clause>

    $where->clause(
        ['and', '{= title}', ['or', '{< date}', '{> date}']]
    );

Where clause. Above one is expanded to the following SQL by to_string
If all parameter names is exists.

    "where ( {= title} and ( {< date} or {> date} ) )"

=head2 C<param>

    my $param = $where->param;
    $where    = $where->param({title => 'Perl',
                               date => ['2010-11-11', '2011-03-05']},
                               name => ['Ken', 'Taro']);

=head2 C<safety_character>

    my $safety_character = $self->safety_character;
    $dbi                 = $self->safety_character($name);

=head1 METHODS

=head2 C<to_string>

    $where->to_string;

Convert where clause to string correspoinding to param name.

=cut
