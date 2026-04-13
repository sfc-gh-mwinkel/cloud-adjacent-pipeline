{% macro set_incremental_query_tag() %}
    {#
        Sets a query tag only for incremental model runs.
        Usage: Add +pre_hook: "{{ set_incremental_query_tag() }}" to dbt_project.yml
    #}
    {% if model.config.materialized == 'incremental' %}
        ALTER SESSION SET QUERY_TAG = 'dbt_incremental_{{ this.name }}'
    {% endif %}
{% endmacro %}

