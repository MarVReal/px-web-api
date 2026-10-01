-- Private bucket `task-attachments` (25 MB limit). Object path: <task_id>/<uuid>-<file name>; access follows task visibility.
insert into storage.buckets (id, name, public, file_size_limit) values ('task-attachments', 'task-attachments', false, 26214400)
  on conflict (id) do nothing;
create policy px_attach_select on storage.objects for select to authenticated
  using (bucket_id = 'task-attachments' and public.can_view_task(((storage.foldername(name))[1])::uuid));
create policy px_attach_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'task-attachments' and public.can_view_task(((storage.foldername(name))[1])::uuid));
create policy px_attach_delete on storage.objects for delete to authenticated
  using (bucket_id = 'task-attachments' and (owner = auth.uid() or public.can_edit_task(((storage.foldername(name))[1])::uuid)));
