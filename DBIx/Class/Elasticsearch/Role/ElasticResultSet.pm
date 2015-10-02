package DBIx::Class::Elasticsearch::Role::ElasticResultSet;

use strict;
use warnings;

use DBIx::Class::ResultClass::HashRefInflator;
use Hash::Flatten qw(:all);

use Moose::Role;

=head2
sub es_has_searchable {
    my $self = shift;

    return scalar $self->es_searchable_fields;
}

sub es_is_child {

    return 1 if shift->result_source->source_info->{es_parent_object};
}

sub es_is_parent {

    return 1 if scalar @{ shift->result_source->source_info->{es_child_objects} };
}

sub es_parent {

    return shift->result_source->source_info->{es_parent_object};
}

sub es_childs {

    return shift->result_source->source_info->{es_child_objects};
}

sub es_searchable_fields {
    my $self = shift;

    my $class             = $self->result_class;
    my $cols              = $class->columns_info;
    my @searchable_fields = grep { $cols->{$_}->{searchable} } keys %{$cols};

    return @searchable_fields;
}

sub es_build_prefetch_columns {

    my ( $self, $wanted_relations_path ) = @_;

    my $flat = flatten( { paths => $wanted_relations_path } );

    my $known_relations = {};

    my $columns = { map { $_ => $_ } $self->es_searchable_fields };

    for my $key ( sort keys %$flat ) {

        my $rs       = $self;
        my $rel_path = $key;
        $rel_path =~ s/paths:\d+\.?//;

        my $last_relations = [];

        if ($rel_path) {    # is a relation path

            my @relations = split( /\./, $rel_path );
            push @relations, $flat->{$key};
            my $size = scalar @relations;

            my $i = 1;

            # every relation in path
            for my $rel (@relations) {

                $rel =~ s/:\d//;

                $known_relations->{$rel}++;

                # rs is going deeper for each key
                $rs = $self->result_source->schema->resultset( $rs->result_source->related_class($rel) );

                my $rel_fields = [ $rs->es_searchable_fields ];

                $rel = sprintf( '%s_%d', $rel, $known_relations->{$rel} ) if $known_relations->{$rel} > 1 && $i < $size;

                for my $rel_field (@$rel_fields) {

                    my $column_name = sprintf( '%s.%s', $rel, $rel_field );
                    my $column_identifier = scalar @$last_relations ? sprintf( '%s.%s', join( '.', @$last_relations ), $column_name ) : $column_name;    # NOTE sry, but i needed to...
                    $columns->{$column_identifier} = $column_name;
                }

                push @$last_relations, $rel;
            }

        } else {    # is a single relation

            my $rel = $flat->{$key};

            $rs = $self->result_source->schema->resultset( $rs->result_source->related_class($rel) );
            my $rel_fields = [ $rs->es_searchable_fields ];

            for my $rel_field (@$rel_fields) {

                my $column_name = sprintf( '%s.%s', $rel, $rel_field );
                $columns->{$column_name} = $column_name;
            }
        }
    }

    return $columns;
}

sub es_build_prefetch {

    my ($self) = @_;

    return $self unless my $wanted_relations_path = $self->result_source->source_info->{es_nested_objects_path};

    # join + collapse + "+columns" == prefetch, idea by <ilmari>
    return { prefetch => $wanted_relations_path };
}

sub es_fetch_with_nested_relations {

    my $self = shift;

    return $self->search( undef, $self->es_build_prefetch );

}

sub es_index {

    my $self = shift;

    warn "for big resultsets you should use es_batch_index" if $self->count >= 10;

    while ( my $row = $self->next ) {

        $row->es_index;
    }
}
=cut

sub es_index {

    my $self    = shift;
    my $dbix_rs = shift;

    my $results = $self->index_rs($dbix_rs);

    $results->result_class('DBIx::Class::ResultClass::HashRefInflator');

    while ( my $row = $results->next ) {

        $row->{es_id} = $self->es_id( $row, $results );

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

sub es_batch_index {
    warn "Batch Indexing...\n";

    my $self = shift;
    my $rs   = shift;

    my $batch_size = shift || 1000;
    my $data = [];

    my $dbix_rs = $self->dbix_rs;
    my $results = $self->index_rs($dbix_rs);    # add prefetches

    $results->result_class('DBIx::Class::ResultClass::HashRefInflator');

    my $counter = 0;

    while ( my $row = $results->next ) {
        $counter++;

        $row->{es_id} = $self->es_id( $row, $dbix_rs );

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

=head2
sub es_build_field_mapping {

    my ($self) = @_;

    my $source = $self->result_source;

    return unless $self->es_has_searchable;

    my @fields = $self->es_searchable_fields;

    my $mapping = {};

    my $type_translations = {

        varchar  => { type => "string", index            => "analyzed" },
        enum     => { type => "string", index            => "not_analyzed", store => "yes" },
        char     => { type => "string", index            => "not_analyzed", store => "yes" },
        date     => { type => "date",   ignore_malformed => 1 },
        datetime => { type => "date",   ignore_malformed => 1 },
        text     => { type => "string", index            => "analyzed", store => "yes", "term_vector" => "with_positions_offsets" },
        integer => { type => "integer", index => "not_analyzed", store => "yes" },
        float   => { type => "float",   index => "not_analyzed", store => "yes" },
        decimal => { type => "float",   index => "not_analyzed", store => "yes" },

    };

    for my $field (@fields) {

        my $column_info         = $source->column_info($field);
        my $mapping_translation = $type_translations->{ $column_info->{data_type} } || {};
        my $elastic_mapping     = $column_info->{elastic_mapping} || {};

        my $merged = { %$mapping_translation, %$elastic_mapping };

        $mapping->{$field} = $merged if $merged;
    }

    return $mapping;
}

sub es_is_primary {

    my $self = shift;

    my $source = $self->result_source;

    return unless $source->source_info && $source->source_info->{es_index_type} eq 'primary';
    return 1;
}

sub es_mapping {

    my ($self) = @_;

    my $wanted_relations_path = $self->result_source->source_info->{es_nested_object_paths};
    my $source                = $self->result_source;

    return $self unless $self->es_is_primary;

    my $mapping = {};

    if ($wanted_relations_path) {
        my $flat = flatten( { paths => $wanted_relations_path } );

        for my $key ( keys %$flat ) {

            my $rs       = $self;
            my $rel_path = $key;
            $rel_path =~ s/paths:\d+\.?//;

            my $last_relations          = [];
            my $temporary_mapping_store = {};

            if ($rel_path) {    # is a relation path

                my @relations = split( /\./, $rel_path );

                push @relations, $flat->{$key};    # the last relation is an value and not included in the key
                my $parent_rel;
                my $parent_class;

                # every relation in path
                for my $rel (@relations) {

                    $rel =~ s/:\d//;

                    # rs is going deeper for each key
                    $rs = $self->result_source->schema->resultset( $rs->result_source->related_class($rel) );

                    my $name = $rs->result_source->source_name;

                    die "resultset $name has no searchable fields" unless $rs->es_has_searchable;

                    $temporary_mapping_store->{$rel} = { class => $rs->result_source->source_name, fields => $rs->es_build_field_mapping };
                    $temporary_mapping_store->{$rel}{parent_rel}   = $parent_rel   if $parent_rel;
                    $temporary_mapping_store->{$rel}{parent_class} = $parent_class if $parent_class;

                    push @$last_relations, $rel;
                    $parent_rel   = $rel;
                    $parent_class = $rs->result_source->source_name;
                }

            } else {    # is a single relation

                my $rel = $flat->{$key};

                $rs = $self->result_source->schema->resultset( $rs->result_source->related_class($rel) );

                my $name = $rs->result_source->source_name;
                die "resultset $name  has no searchable fields" unless $rs->es_has_searchable;

                $temporary_mapping_store->{$rel} = { class => $rs->result_source->source_name, fields => $rs->es_build_field_mapping };

                push @$last_relations, $rel;

            }

            my $build_mapping = {};

            my $relation_type_translations = {
                single => "object",
                multi  => "nested",
            };

            my $parent = {};

            for my $rel (@$last_relations) {

                my $row          = $temporary_mapping_store->{$rel};
                my $class        = $row->{class};
                my $fields       = $row->{fields};
                my $parent_rel   = $row->{parent_rel};
                my $parent_class = $row->{parent_class};

                my $rs = $parent_class ? $source->schema->resultset($parent_class) : $self;

                my $relation_mapping = {};

                my $relation_info = $rs->result_source->relationship_info($rel);

                $parent->{$rel} = $relation_mapping;

                $relation_mapping->{type}       = $relation_type_translations->{ $relation_info->{attrs}{accessor} };
                $relation_mapping->{properties} = $fields;

                if ($parent_rel) {

                    $parent->{$parent_rel}{properties}{$rel} = $relation_mapping;
                } else {

                    $mapping->{$rel} = $relation_mapping;
                }

            }

        }

    }

    $mapping = { %$mapping, %{ $self->es_build_field_mapping } };

    # add parent if available
    $mapping->{"_parent"}{type} = $self->es_parent if $self->es_is_child;

    return $mapping;

}
=cut

1;
