{{
    config(
        materialized='incremental',
        unique_key='user_id',
        on_schema_change=(var('ci_on_schema_change', 'sync_all_columns') if target.name == 'check' else 'sync_all_columns')
    )
}}

with user_summary as (
    select * from {{ ref('int_user_event_summary') }}
),

final as (
    select
        user_id,
        purchase_count,
        refund_count,
        gross_revenue,
        total_refunds,
        gross_revenue - total_refunds  as net_revenue,
        purchase_count + refund_count as total_event_count,
        gross_revenue = 0              as has_zero_gross_revenue,
        last_event_at,
        current_timestamp()            as dbt_updated_at
    from user_summary
)

select * from final

{% if is_incremental() %}
    where
        (select max(last_event_at) from {{ this }}) is null
        or last_event_at > (select max(last_event_at) from {{ this }})
{% endif %}
