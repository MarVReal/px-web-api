-- Per-pipeline Kanban card layout: ordered list of {key, width} items (null = default layout).
-- Validated structurally in the app; the database only guards shape and size.
alter table pipelines add column card_layout jsonb;
alter table pipelines add constraint pipelines_card_layout_chk
  check (card_layout is null or (jsonb_typeof(card_layout) = 'array' and jsonb_array_length(card_layout) <= 40));
