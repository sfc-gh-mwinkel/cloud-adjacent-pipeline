{#
    Removes a recent time window from incremental models cloned by `dbt clone`.
    This makes the following CI build exercise each model's incremental branch.
#}

{% macro clone_incrementals_for_ci() %}
    {% if not execute %}
        {{ return('') }}
    {% endif %}

    {% if flags.WHICH not in ['run', 'build'] %}
        {{ return('') }}
    {% endif %}

    {% set ci_target_names = var('ci_target_names', ['ci', 'pr', 'slim_ci', 'check']) %}
    {% set is_ci = target.name | lower in ci_target_names %}
    {% set is_dbt_cloud_ci = 'dbt_cloud_pr' in (target.schema | lower) %}

    {% if not (is_ci or is_dbt_cloud_ci) or not var('ci_clone_enabled', true) %}
        {{ return('') }}
    {% endif %}

    {% set default_trim_days = var('ci_trim_days', 1) %}
    {% set default_timestamp_column = var('ci_timestamp_column', none) %}
    {% set results = namespace(trimmed=0, skipped=0, misconfigured=0) %}

    {{ log('CI incremental clone trimming', info=true) }}

    {% for resource in selected_resources %}
        {% if resource in graph.nodes %}
            {% set node = graph.nodes[resource] %}

            {% if node.resource_type == 'model' and node.config.materialized == 'incremental' %}
                {% set meta = node.meta if node.meta is defined else {} %}
                {% set timestamp_column = meta.get('ci_trim_timestamp_column', default_timestamp_column) %}
                {% set trim_days = meta.get('ci_trim_days', default_trim_days) %}
                {% set relation = adapter.get_relation(
                    database=node.database,
                    schema=node.schema,
                    identifier=node.alias
                ) %}

                {% if trim_days is not number or trim_days | int != trim_days or trim_days | int <= 0 %}
                    {% do exceptions.raise_compiler_error(
                        node.name ~ ': ci_trim_days must be a positive integer; received ' ~ trim_days
                    ) %}
                {% endif %}

                {% if relation is none %}
                    {% set results.skipped = results.skipped + 1 %}
                    {{ log('  ' ~ node.name ~ ': no cloned relation; skipping trim', info=true) }}
                {% elif timestamp_column is none %}
                    {% set results.misconfigured = results.misconfigured + 1 %}
                    {% do exceptions.raise_compiler_error(
                        node.name ~ ': ci_trim_timestamp_column is required for a cloned incremental model'
                    ) %}
                {% else %}
                    {% set relation_columns = adapter.get_columns_in_relation(relation) %}
                    {% set column_names = relation_columns | map(attribute='name') | map('lower') | list %}

                    {% if timestamp_column | lower not in column_names %}
                        {% set results.misconfigured = results.misconfigured + 1 %}
                        {% do exceptions.raise_compiler_error(
                            node.name ~ ': configured CI trim column ' ~ timestamp_column ~ ' is not present in ' ~ relation
                        ) %}
                    {% else %}
                        {% set trim_sql %}
                            delete from {{ relation }}
                            where {{ adapter.quote(timestamp_column) }} >= dateadd(
                                day,
                                -{{ trim_days | int }},
                                (select max({{ adapter.quote(timestamp_column) }}) from {{ relation }})
                            )
                        {% endset %}
                        {% do run_query(trim_sql) %}
                        {% set results.trimmed = results.trimmed + 1 %}
                        {{ log('  ' ~ node.name ~ ': removed the latest data-relative ' ~ trim_days ~ ' day(s)', info=true) }}
                    {% endif %}
                {% endif %}
            {% endif %}
        {% endif %}
    {% endfor %}

    {{ log(
        'CI trim summary: trimmed=' ~ results.trimmed
        ~ ' skipped=' ~ results.skipped
        ~ ' misconfigured=' ~ results.misconfigured,
        info=true
    ) }}
{% endmacro %}