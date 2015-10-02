package DBIx::Class::Elasticsearch::Role::ElasticResult;

use strict;
use warnings;

use Moose::Role;

sub es_index {

    my $self = shift;

    my $schema = $self->result_source->schema;
    my $class  = $self->result_source->source_name;

    my $elastic_rs = $schema->dispatcher->{$class};

    for my $rs (@$elastic_rs) {

        eval "use $rs";

        die $@ if $@;

        my $obj = $self->es_obj_builder($rs);
        my $dbic_rs = $self->es_dbic_builder( $rs, $obj );

        $rs->es_index($dbic_rs);
    }
}

sub es_obj_builder {

    my $self = shift;
    my $rs   = shift;

    my $class = $self->result_source->source_name;

    my $obj = $self;

    if ( $rs->es_is_primary($class) ) {

    } elsif ( $rs->es_is_nested($class) ) {

        my $obj_source = $obj->result_source->source_name;

        while ( !$rs->es_is_primary($obj_source) ) {

            my $rel = $rs->relation_dispatcher->{nested}{$obj_source};

            $obj        = $obj->$rel;
            $obj_source = $obj->result_source->source_name;

        }

    }

    return $obj;

}

sub es_dbic_builder {

    my $self = shift;
    my $rs   = shift;
    my $obj  = shift;

    my $dbic_rs     = $rs->index_rs;
    my $me          = $dbic_rs->current_source_alias;
    my $dbic_params = { map { $me . "." . $_ => $obj->$_ } $obj->result_source->primary_columns };

    $dbic_rs = $dbic_rs->search_rs($dbic_params);

    return $dbic_rs;
}

sub es_delete {

    my ($self) = @_;

    my $schema = $self->result_source->schema;
    my $class  = $self->result_source->source_name;

    my $elastic_rs = $schema->dispatcher->{$class};

    for my $rs (@$elastic_rs) {

        eval "use $rs";

        die $@ if $@;

        my $obj     = $self->es_obj_builder($rs);
        my $dbic_rs = $self->es_dbic_builder($rs, $obj);

        if ( $rs->es_is_primary( $class ) ) {

            $rs->es_delete($dbic_rs);

        } elsif( $rs->es_is_nested($class) ) {

            $rs->es_index($dbic_rs);
        }
    }
}

after 'insert' => sub {
    my $self = shift;

    warn "Inserting ...\n";
    $self->es_index;
};

after 'update' => sub {
    my $self = shift;

    warn "Updating ...\n";
    $self->es_index;
};

before 'delete' => sub {
    my $self = shift;

    warn "Deleting...\n";
    $self->es_delete;
};

sub es_index_transfer {

    my ( $self, $body ) = @_;

    my $type = $self->result_source->name;

    my $parent = {};
    if ( $self->es_is_child ) {

        $parent = { parent => $self->es_parent };
    }

}

sub es {

    return shift->result_source->schema->es;
}

1;
