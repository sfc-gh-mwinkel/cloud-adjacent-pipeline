with events as (
    select * from {{ ref('stg_events') }}
),

summarized as (
    select
        user_id,
        count_if(event_type = 'purchase')                           as purchase_count,
        count_if(event_type = 'refund')                             as refund_count,
        sum(case when event_type = 'purchase' then amount else 0 end) as gross_revenue,
        sum(case when event_type = 'refund' then amount else 0 end)   as total_refunds,
        sum(case when event_type = 'purchase' then amount else 0 end)
            - sum(case when event_type = 'refund' then amount else 0 end) as net_revenue,
        max(updated_at)                                             as last_event_at
    from events
    group by 1
)

select * from summarized
