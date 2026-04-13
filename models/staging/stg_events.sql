with source as (
    select * from {{ source('cloud_adjacent_pipeline', 'raw_events') }}
),

renamed as (
    select
        id::integer          as event_id,
        event_type,
        user_id,
        amount::float        as amount,
        status,
        updated_at::timestamp as updated_at
    from source
)

select * from renamed
