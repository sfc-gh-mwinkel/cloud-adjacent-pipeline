{#
    ============================================================================
    CUSTOM DATABASE AND SCHEMA NAME GENERATION
    ============================================================================
    
    Overrides dbt's default behavior for database and schema assignment.
    
    BEHAVIOR:
    - uat/prod targets: Use the custom database/schema from model config
    - All other targets (dev/CI):
        - If the model has a custom schema configured, build into
          <custom_schema>_<target.schema>  (e.g. marts_dbt_pr_42)
        - If no custom schema is configured, build into target.schema as-is
          (e.g. dbt_pr_42)
    
    This ensures:
    - Dev/CI builds are isolated to target.database and namespaced per layer
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
        {# Dev/CI/Other: Append target.schema suffix to the custom schema name #}
        {%- if custom_schema_name is not none -%}
            {{ custom_schema_name | trim }}_{{ target.schema }}
        {%- else -%}
            {{ target.schema }}
        {%- endif -%}
    {%- endif -%}

{%- endmacro %}
