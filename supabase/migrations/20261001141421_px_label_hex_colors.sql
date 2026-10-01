-- Label colours are free-form hex (#rrggbb) instead of preset names.
alter table pipeline_categories alter column color drop default;
alter table pipeline_tags alter column color drop default;

update pipeline_categories set color = case color
  when 'gray' then '#667085' when 'blue' then '#2e90fa' when 'green' then '#12b76a' when 'orange' then '#f79009'
  when 'red' then '#f04438' when 'purple' then '#7a5af8' when 'pink' then '#ee46bc' when 'teal' then '#15b79e' else color end;
update pipeline_tags set color = case color
  when 'gray' then '#667085' when 'blue' then '#2e90fa' when 'green' then '#12b76a' when 'orange' then '#f79009'
  when 'red' then '#f04438' when 'purple' then '#7a5af8' when 'pink' then '#ee46bc' when 'teal' then '#15b79e' else color end;
-- anything unexpected falls back to neutral gray so the constraint can be added
update pipeline_categories set color = '#667085' where color !~ '^#[0-9a-fA-F]{6}$';
update pipeline_tags set color = '#667085' where color !~ '^#[0-9a-fA-F]{6}$';

alter table pipeline_categories alter column color set default '#667085';
alter table pipeline_tags alter column color set default '#2e90fa';
alter table pipeline_categories add constraint pipeline_categories_color_hex check (color ~ '^#[0-9a-fA-F]{6}$');
alter table pipeline_tags add constraint pipeline_tags_color_hex check (color ~ '^#[0-9a-fA-F]{6}$');
