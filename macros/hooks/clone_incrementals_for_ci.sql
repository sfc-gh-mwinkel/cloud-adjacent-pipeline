{#
    ============================================================================
    CI PRE-BUILD HOOK: Clone Legacy Tables for Slim CI
    ============================================================================
    
    Automatically clones legacy tables into the CI schema before incremental 
    models run, enabling true incremental builds instead of full refreshes.
    
    REQUIREMENTS:
    - Models must have +database and +schema defined in dbt_project.yml
    - Model names must follow: <prefix>__<table_name> OR use meta.legacy_name
    
    HOW IT WORKS:
    1. Fires when target.name matches ci_target_names (or dbt Cloud CI schema)
    2. For each selected incremental model:
       - Legacy database: meta.legacy_database → node.config.database → target.database
       - Legacy schema: meta.legacy_schema → node.config.schema → target.schema
       - Legacy table: meta.legacy_name → parsed from model name (after '__')
       - CI location: target.database, target.schema (from CI target)
    3. Clones legacy table to CI schema, truncates recent data
    
    NOTE: Uses node.config.database/schema (raw config) not node.database/schema
    (which are transformed by generate_database_name/generate_schema_name)
    
    LEGACY LOCATION RESOLUTION (each property resolved independently):
    
    Database: meta.legacy_database → node.database
    Schema:   meta.legacy_schema   → node.schema
    Table:    meta.legacy_name     → parsed from model name (after '__')
    
    EXAMPLE 1 - Full override:
    Model: fct_charges
    meta: legacy_database: ARCHIVE, legacy_schema: HISTORY, legacy_name: OLD_CHARGES
    Clone FROM: ARCHIVE.HISTORY.OLD_CHARGES
    
    EXAMPLE 2 - Partial override:
    Model: stg_epmemr__rs_clinic
    meta: legacy_name: CLINIC_MASTER  (database/schema from node config)
    Clone FROM: EPROD.EPMEMR.CLINIC_MASTER
    
    EXAMPLE 3 - No override:
    Model: stg_epmemr__rs_clinic
    Clone FROM: EPROD.EPMEMR.RS_CLINIC (all from node config + parsed name)
    
    MODEL YML EXAMPLE:
    
        models:
          - name: fct_charges
            meta:
              legacy_database: ARCHIVE    # optional
              legacy_schema: HISTORY      # optional
              legacy_name: OLD_CHARGES    # optional
    
    CONFIGURATION (dbt_project.yml):
    
        on-run-start:
          - "{{ clone_incrementals_for_ci() }}"
        
        vars:
          ci_target_names: ['ci', 'pr', 'slim_ci', 'check']
          ci_truncate_days: 1
          ci_timestamp_column: 'ingestiontime'
          ci_clone_enabled: true
    
    ============================================================================
#}

{% macro clone_incrementals_for_ci() %}
    
    {% if not execute %}
        {{ return('') }}
    {% endif %}
    
    {# ===== CI DETECTION ===== #}
    {% set ci_target_names = var('ci_target_names', ['ci', 'pr', 'slim_ci', 'check']) %}
    {% set is_ci = target.name | lower in ci_target_names %}
    {% set is_dbt_cloud_ci = 'dbt_cloud_pr' in (target.schema | lower) %}
    
    {% if not (is_ci or is_dbt_cloud_ci) %}
        {{ return('') }}
    {% endif %}
    
    {% if not var('ci_clone_enabled', true) %}
        {{ log("CI Clone Hook: Disabled via ci_clone_enabled=false", info=true) }}
        {{ return('') }}
    {% endif %}
    
    {# ===== SETTINGS ===== #}
    {% set truncate_days = var('ci_truncate_days', 1) %}
    {% set timestamp_column = var('ci_timestamp_column', 'ingestiontime') %}
    
    {# ===== FIND INCREMENTAL MODELS TO CLONE ===== #}
    {% set models_to_clone = [] %}
    
    {% for resource in selected_resources %}
        {% if resource in graph.nodes %}
            {% set node = graph.nodes[resource] %}
            
            {% if node.resource_type == 'model' and node.config.materialized == 'incremental' %}
                {% set model_name = node.name %}
                {% set meta = node.meta if node.meta is defined else {} %}
                
                {# === LEGACY DATABASE === #}
                {# Priority: meta.legacy_database → node.config.database → target.database #}
                {% if meta.legacy_database is defined %}
                    {% set legacy_database = meta.legacy_database | upper %}
                    {% set db_source = 'meta' %}
                {% elif node.config.database is defined and node.config.database is not none %}
                    {% set legacy_database = node.config.database | upper %}
                    {% set db_source = 'config' %}
                {% else %}
                    {% set legacy_database = target.database | upper %}
                    {% set db_source = 'target' %}
                {% endif %}
                
                {# === LEGACY SCHEMA === #}
                {# Priority: meta.legacy_schema → node.config.schema → target.schema #}
                {% if meta.legacy_schema is defined %}
                    {% set legacy_schema = meta.legacy_schema | upper %}
                    {% set schema_source = 'meta' %}
                {% elif node.config.schema is defined and node.config.schema is not none %}
                    {% set legacy_schema = node.config.schema | upper %}
                    {% set schema_source = 'config' %}
                {% else %}
                    {% set legacy_schema = target.schema | upper %}
                    {% set schema_source = 'target' %}
                {% endif %}
                
                {# === LEGACY TABLE === #}
                {% if meta.legacy_name is defined %}
                    {% set legacy_table = meta.legacy_name | upper %}
                    {% set table_source = 'meta' %}
                {% elif '__' in model_name %}
                    {% set legacy_table = model_name.split('__')[1] | upper %}
                    {% set table_source = 'parsed' %}
                {% else %}
                    {% set legacy_table = none %}
                {% endif %}
                
                {% if legacy_table is not none %}
                    {# Build source description #}
                    {% set legacy_source = 'db:' ~ db_source ~ ' schema:' ~ schema_source ~ ' table:' ~ table_source %}
                    
                    {# CI location from target #}
                    {% set ci_database = target.database | upper %}
                    {% set ci_schema = target.schema | upper %}
                    {% set ci_table = (node.alias or model_name) | upper %}
                    
                    {% do models_to_clone.append({
                        'model_name': model_name,
                        'legacy_database': legacy_database,
                        'legacy_schema': legacy_schema,
                        'legacy_table': legacy_table,
                        'legacy_source': legacy_source,
                        'ci_database': ci_database,
                        'ci_schema': ci_schema,
                        'ci_table': ci_table
                    }) %}
                {% endif %}
            {% endif %}
        {% endif %}
    {% endfor %}
    
    {% if models_to_clone | length == 0 %}
        {{ return('') }}
    {% endif %}
    
    {# ===== HEADER ===== #}
    {{ log("", info=true) }}
    {{ log("=" * 70, info=true) }}
    {{ log("CI PRE-BUILD: Cloning Legacy Tables", info=true) }}
    {{ log("=" * 70, info=true) }}
    {{ log("CI Target: " ~ target.database ~ "." ~ target.schema, info=true) }}
    {{ log("Truncate: " ~ truncate_days ~ " day(s) via " ~ timestamp_column, info=true) }}
    {{ log("Models: " ~ models_to_clone | length, info=true) }}
    {{ log("=" * 70, info=true) }}
    
    {# ===== CLONE EACH MODEL ===== #}
    {% set results = {'cloned': 0, 'skipped': 0, 'not_found': 0} %}
    
    {% for m in models_to_clone %}
        {% set legacy_fqn = m.legacy_database ~ '.' ~ m.legacy_schema ~ '.' ~ m.legacy_table %}
        {% set ci_fqn = m.ci_database ~ '.' ~ m.ci_schema ~ '.' ~ m.ci_table %}
        
        {{ log("", info=true) }}
        {{ log(m.model_name ~ " (" ~ m.legacy_source ~ ")", info=true) }}
        {{ log("  FROM: " ~ legacy_fqn, info=true) }}
        {{ log("  TO:   " ~ ci_fqn, info=true) }}
        
        {# Check if legacy exists #}
        {% set check_sql = "SELECT COUNT(*) FROM " ~ m.legacy_database ~ ".INFORMATION_SCHEMA.TABLES WHERE UPPER(TABLE_SCHEMA)='" ~ m.legacy_schema ~ "' AND UPPER(TABLE_NAME)='" ~ m.legacy_table ~ "'" %}
        {% if run_query(check_sql).columns[0].values()[0] == 0 %}
            {{ log("  ⏭️  Legacy not found", info=true) }}
            {% do results.update({'not_found': results.not_found + 1}) %}
        {% else %}
            {# Check if CI table already exists #}
            {% set check_ci = "SELECT COUNT(*) FROM " ~ m.ci_database ~ ".INFORMATION_SCHEMA.TABLES WHERE UPPER(TABLE_SCHEMA)='" ~ m.ci_schema ~ "' AND UPPER(TABLE_NAME)='" ~ m.ci_table ~ "'" %}
            {% if run_query(check_ci).columns[0].values()[0] > 0 %}
                {{ log("  ⏭️  Already exists in CI", info=true) }}
                {% do results.update({'skipped': results.skipped + 1}) %}
            {% else %}
                {# Clone #}
                {% do run_query("CREATE TRANSIENT TABLE " ~ ci_fqn ~ " CLONE " ~ legacy_fqn) %}
                {{ log("  ✅ Cloned", info=true) }}
                
                {# Truncate recent data #}
                {% set col_check = "SELECT COUNT(*) FROM " ~ m.ci_database ~ ".INFORMATION_SCHEMA.COLUMNS WHERE UPPER(TABLE_SCHEMA)='" ~ m.ci_schema ~ "' AND UPPER(TABLE_NAME)='" ~ m.ci_table ~ "' AND UPPER(COLUMN_NAME)='" ~ timestamp_column | upper ~ "'" %}
                {% if run_query(col_check).columns[0].values()[0] > 0 %}
                    {% set before = run_query("SELECT COUNT(*) FROM " ~ ci_fqn).columns[0].values()[0] %}
                    {% do run_query("DELETE FROM " ~ ci_fqn ~ " WHERE " ~ timestamp_column ~ " > DATEADD(day, -" ~ truncate_days ~ ", CURRENT_DATE())") %}
                    {% set after = run_query("SELECT COUNT(*) FROM " ~ ci_fqn).columns[0].values()[0] %}
                    {{ log("  ✂️  Truncated " ~ (before - after) ~ " rows (" ~ after ~ " remain)", info=true) }}
                {% else %}
                    {{ log("  ⚠️  No " ~ timestamp_column ~ " column, skip truncate", info=true) }}
                {% endif %}
                
                {% do results.update({'cloned': results.cloned + 1}) %}
            {% endif %}
        {% endif %}
    {% endfor %}
    
    {# ===== SUMMARY ===== #}
    {{ log("", info=true) }}
    {{ log("=" * 70, info=true) }}
    {{ log("SUMMARY: Cloned=" ~ results.cloned ~ " Skipped=" ~ results.skipped ~ " NotFound=" ~ results.not_found, info=true) }}
    {{ log("=" * 70, info=true) }}
    
    {% if results.cloned > 0 %}
        {{ log("✅ CI ready - incrementals will run incrementally!", info=true) }}
    {% endif %}
    
{% endmacro %}


{# ============================================================================
   DIAGNOSTIC: Preview what would be cloned
   ============================================================================ #}

{% macro show_clone_resolution() %}
    {{ log("", info=true) }}
    {{ log("=" * 70, info=true) }}
    {{ log("CLONE RESOLUTION PREVIEW", info=true) }}
    {{ log("=" * 70, info=true) }}
    {{ log("Current target: " ~ target.database ~ "." ~ target.schema, info=true) }}
    {{ log("", info=true) }}
    
    {% for node in graph.nodes.values() %}
        {% if node.resource_type == 'model' and node.config.materialized == 'incremental' %}
            {% set model_name = node.name %}
            {% set meta = node.meta if node.meta is defined else {} %}
            
            {{ log("Model: " ~ model_name, info=true) }}
            {{ log("  node.config.database: " ~ node.config.database, info=true) }}
            {{ log("  node.config.schema:   " ~ node.config.schema, info=true) }}
            
            {# Show meta overrides if present #}
            {% if meta.legacy_database is defined %}
                {{ log("  meta.legacy_database: " ~ meta.legacy_database, info=true) }}
            {% endif %}
            {% if meta.legacy_schema is defined %}
                {{ log("  meta.legacy_schema: " ~ meta.legacy_schema, info=true) }}
            {% endif %}
            {% if meta.legacy_name is defined %}
                {{ log("  meta.legacy_name: " ~ meta.legacy_name, info=true) }}
            {% endif %}
            
            {# Resolve legacy location - same priority as hook #}
            {% if meta.legacy_database is defined %}
                {% set legacy_database = meta.legacy_database | upper %}
            {% elif node.config.database is defined and node.config.database is not none %}
                {% set legacy_database = node.config.database | upper %}
            {% else %}
                {% set legacy_database = target.database | upper %}
            {% endif %}
            
            {% if meta.legacy_schema is defined %}
                {% set legacy_schema = meta.legacy_schema | upper %}
            {% elif node.config.schema is defined and node.config.schema is not none %}
                {% set legacy_schema = node.config.schema | upper %}
            {% else %}
                {% set legacy_schema = target.schema | upper %}
            {% endif %}
            
            {% if meta.legacy_name is defined %}
                {% set legacy_table = meta.legacy_name | upper %}
            {% elif '__' in model_name %}
                {% set legacy_table = model_name.split('__')[1] | upper %}
            {% else %}
                {% set legacy_table = none %}
            {% endif %}
            
            {% if legacy_table is not none %}
                {{ log("  Clone FROM: " ~ legacy_database ~ "." ~ legacy_schema ~ "." ~ legacy_table, info=true) }}
                {{ log("  Clone TO:   " ~ target.database | upper ~ "." ~ target.schema | upper ~ "." ~ model_name | upper, info=true) }}
            {% else %}
                {{ log("  ⚠️  Cannot resolve legacy table (no meta.legacy_name and no '__' in name)", info=true) }}
            {% endif %}
            {{ log("", info=true) }}
        {% endif %}
    {% endfor %}
{% endmacro %}
