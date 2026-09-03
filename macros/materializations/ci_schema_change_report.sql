{#
    dbt-adapters 1.16.3 compatibility override.

    This mirrors dbt's process_schema_changes macro and adds CI-only structured
    logging. Review this macro whenever the pinned dbt dependencies are upgraded.
#}

{% macro ci_schema_change_marker() %}DBT_CI_SCHEMA_DRIFT{% endmacro %}

{% macro ci_column_names(columns) %}
    {% set names = [] %}
    {% for column in columns %}
        {% do names.append(column.name) %}
    {% endfor %}
    {{ return(names) }}
{% endmacro %}

{% macro process_schema_changes(on_schema_change, source_relation, target_relation) %}
    {% if on_schema_change == 'ignore' %}
        {{ return({}) }}
    {% endif %}

    {% set schema_changes_dict = check_for_schema_changes(source_relation, target_relation) %}

    {% if schema_changes_dict['schema_changed'] %}
        {% if target.name == 'check' %}
            {% set drift = {
                'model': model.name if model is defined else target_relation.identifier,
                'relation': target_relation | string,
                'added_columns': ci_column_names(schema_changes_dict['source_not_in_target']),
                'removed_columns': ci_column_names(schema_changes_dict['target_not_in_source']),
                'changed_types': schema_changes_dict['new_target_types'],
                'recommendation': 'Review this change for a production full refresh; schema synchronization does not backfill historical rows.'
            } %}
            {{ log(ci_schema_change_marker() ~ ' ' ~ tojson(drift), info=true) }}
        {% endif %}

        {% if on_schema_change == 'fail' %}
            {% set fail_msg %}
                The source and target schemas on this incremental model are out of sync!
                Source columns not in target: {{ schema_changes_dict['source_not_in_target'] }}
                Target columns not in source: {{ schema_changes_dict['target_not_in_source'] }}
                New column types: {{ schema_changes_dict['new_target_types'] }}
            {% endset %}
            {% do exceptions.raise_compiler_error(fail_msg) %}
        {% else %}
            {% do sync_column_schemas(on_schema_change, target_relation, schema_changes_dict) %}
        {% endif %}
    {% endif %}

    {{ return(schema_changes_dict['source_columns']) }}
{% endmacro %}