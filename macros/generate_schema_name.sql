{#
    ============================================================================
    CUSTOM DATABASE AND SCHEMA NAME GENERATION
    ============================================================================
    
    Overrides dbt's default behavior for database and schema assignment.
    
    BEHAVIOR:
    - uat/prod targets: Use the custom database/schema from model config
    - All other targets: Use target.database and target.schema (ignores config)
    
    This ensures:
    - Dev/CI builds go to isolated locations (target.database.target.schema)
    - UAT/Prod builds respect the configured database/schema structure
    
    ============================================================================
#}


{% macro generate_database_name(custom_database_name=none, node=none) -%}

    {%- set production_targets = ['uat', 'prod', 'production'] -%}
    
    {%- if target.name | lower in production_targets -%}
        {# UAT/Prod: Use custom database if defined, otherwise target default #}
        {%- if custom_database_name is not none -%}
            {{ custom_database_name | trim }}
        {%- else -%}
            {{ target.database }}
        {%- endif -%}
    {%- else -%}
        {# Dev/CI/Other: Always use target.database #}
        {{ target.database }}
    {%- endif -%}

{%- endmacro %}


{% macro generate_schema_name(custom_schema_name=none, node=none) -%}

    {%- set production_targets = ['uat', 'prod', 'production'] -%}
    
    {%- if target.name | lower in production_targets -%}
        {# UAT/Prod: Use custom schema if defined, otherwise target default #}
        {%- if custom_schema_name is not none -%}
            {{ custom_schema_name | trim }}
        {%- else -%}
            {{ target.schema }}
        {%- endif -%}
    {%- else -%}
        {# Dev/CI/Other: Always use target.schema #}
        {{ target.schema }}
    {%- endif -%}

{%- endmacro %}
