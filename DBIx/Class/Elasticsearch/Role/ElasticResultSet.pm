package DBIx::Class::Elasticsearch::Role::ElasticResultSet;

use strict;
use warnings;

use DBIx::Class::ResultClass::HashRefInflator;
use Hash::Flatten qw(:all);

use Moose::Role;

sub es_index {

    my $self    = shift;
    my $dbic_rs = shift;

    $dbic_rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    while ( my $row = $dbic_rs->next ) {

        $row->{es_id} = $self->es_id( $row, $dbic_rs );

        $self->es->index(
            {
                index => $self->type,
                id    => $row->{es_id},
                type  => $self->type,
                body  => $row,
            }
        );
    }

}

sub es_delete {

    my $self    = shift;
    my $dbic_rs = shift;

    $dbic_rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    while ( my $row = $dbic_rs->next ) {

        my $id = $self->es_id( $row, $dbic_rs );

        $self->es->delete(
            id    => $id,
            type  => $self->type,
            index => $self->type,
        );
    }
}

sub es_is_primary {

    my $self = shift;
    my $class = shift;

    return 1 if $self->relation_dispatcher->{primary} eq $class;
}

sub es_is_nested {

    my $self = shift;
    my $class = shift;

    return 1 if $self->relation_dispatcher->{nested}{ $class };
}

sub es_batch_index {
    warn "Batch Indexing...\n";

    my $self = shift;
    my $rs   = shift;

    my $batch_size = shift || 1000;
    my $data = [];

    my $results = $self->index_rs;    # add prefetches

    $results->result_class('DBIx::Class::ResultClass::HashRefInflator');

    my $counter = 0;

    while ( my $row = $results->next ) {
        $counter++;

        $row->{es_id} = $self->es_id( $row, $results );

        push( @$data, $row );
        if ( $counter == $batch_size ) {
            warn "Batched $counter rows\n";
            $self->es_bulk($data);

            ( $data, $counter ) = ( [], 0 );
        }
    }

    if ( scalar @$data ) {
        warn "Batched " . scalar @$data . " rows\n";
        $self->es_bulk($data) if scalar @$data;
    }

    1;
}

sub es_id {

    my $self = shift;
    my $row  = shift;

    my $pks = $self->es_id_columns;

    my $ids = [];

    for my $pk (@$pks) {

        push @$ids, $row->{$pk};
    }

    return join '_', @$ids;
}

sub es {

    return shift->schema->es;
}

sub es_bulk {

    my ( $self, $data ) = @_;

    my $bulk   = $self->es->bulk_helper;
    my $schema = $self->schema;

    for my $row_raw (@$data) {

        my $row = {};

        for my $key ( keys %$row_raw ) {

            $row->{$key} = $row_raw->{$key} if $row_raw->{$key};
        }

        my $params = {
            index  => $self->type,
            id     => $row->{es_id},
            type   => $self->type,
            source => $row,
        };

        $bulk->index($params);
    }

    $bulk->flush;
}

1;
