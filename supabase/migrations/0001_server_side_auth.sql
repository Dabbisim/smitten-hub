-- ============================================================
-- Move authentication & authorization server-side.
--
-- Until this migration is applied, the Supabase anon key has
-- unrestricted CRUD on every table. After it's applied, only
-- allowlisted admins (admin_emails table) can write anything,
-- public reads still work for the display pages, and the retro
-- form still accepts anonymous submissions but with shape
-- validation enforced by Postgres.
--
-- HOW TO APPLY: copy the four sections below into the Supabase
-- Dashboard SQL editor (one transaction at a time). Apply
-- sections 1 -> 2 -> 3 -> 4 in order.
--
-- ORDER OF DEPLOY (see plan file):
--   1. Deploy the frontend changes (gates voting on sign-in).
--   2. Run section 1 here.
--   3. Run section 2 here (anonymous writes start failing).
--   4. Run section 3 here.
--   5. Verify section 4 in Dashboard -> Database -> Replication.
-- ============================================================


-- ============================================================
-- SECTION 1: admin_emails table + is_admin() helper
-- ============================================================

begin;

create table if not exists public.admin_emails (
  email      text primary key check (email = lower(email)),
  added_at   timestamptz not null default now(),
  added_by   uuid references auth.users(id) on delete set null
);

insert into public.admin_emails (email) values
  ('david@smitten.fun'),
  ('a@smitten.fun'),
  ('magnus@smitten.fun')
on conflict (email) do nothing;

alter table public.admin_emails enable row level security;

-- SECURITY DEFINER lets is_admin() read admin_emails even when
-- the caller has no SELECT policy on it. set search_path locks
-- the function against search_path hijack attacks.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.admin_emails
    where email = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

commit;


-- ============================================================
-- SECTION 2: RLS policies
--
-- Each table block runs inside its own transaction so the table
-- is never RLS-on without policies (which would deny all reads).
-- ============================================================

-- ---- sprints: public read, admin write ----
begin;

alter table public.sprints enable row level security;

create policy "sprints_select_public"
  on public.sprints for select
  to anon, authenticated
  using (true);

create policy "sprints_admin_insert"
  on public.sprints for insert
  to authenticated
  with check (public.is_admin());

create policy "sprints_admin_update"
  on public.sprints for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "sprints_admin_delete"
  on public.sprints for delete
  to authenticated
  using (public.is_admin());

commit;


-- ---- votes: public read, admin write (voting is admin-only) ----
begin;

alter table public.votes enable row level security;

create policy "votes_select_public"
  on public.votes for select
  to anon, authenticated
  using (true);

create policy "votes_admin_insert"
  on public.votes for insert
  to authenticated
  with check (public.is_admin());

create policy "votes_admin_update"
  on public.votes for update
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

create policy "votes_admin_delete"
  on public.votes for delete
  to authenticated
  using (public.is_admin());

commit;


-- ---- retros: anonymous insert with shape check, admin read/delete ----
--
-- Pre-flight: confirm the column names on `retros` in the Table
-- Editor before running this. The WITH CHECK below assumes
-- columns: sprint_id, loved, annoyed, learned, next_try.
-- Adjust if reality differs.
begin;

alter table public.retros enable row level security;

create policy "retros_anon_insert"
  on public.retros for insert
  to anon, authenticated
  with check (
    sprint_id is not null
    and (loved    is null or char_length(loved)    <= 2000)
    and (annoyed  is null or char_length(annoyed)  <= 2000)
    and (learned  is null or char_length(learned)  <= 2000)
    and (next_try is null or char_length(next_try) <= 2000)
    and (
      loved is not null
      or annoyed is not null
      or learned is not null
      or next_try is not null
    )
  );

create policy "retros_admin_select"
  on public.retros for select
  to authenticated
  using (public.is_admin());

create policy "retros_admin_delete"
  on public.retros for delete
  to authenticated
  using (public.is_admin());

commit;


-- ---- admin_emails: admins only ----
begin;

create policy "admin_emails_admin_read"
  on public.admin_emails for select
  to authenticated
  using (public.is_admin());

create policy "admin_emails_admin_write"
  on public.admin_emails for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin());

commit;


-- ============================================================
-- SECTION 3: Defense-in-depth CHECK constraints on retros
--
-- The WITH CHECK in the RLS policy above already enforces shape
-- for INSERTs through the API. These hard table-level constraints
-- catch any future bypass (service-role inserts, schema changes,
-- direct DB access).
-- ============================================================

begin;

alter table public.retros
  add constraint retros_text_len check (
    coalesce(char_length(loved),    0) <= 2000
    and coalesce(char_length(annoyed),  0) <= 2000
    and coalesce(char_length(learned),  0) <= 2000
    and coalesce(char_length(next_try), 0) <= 2000
  );

alter table public.retros
  add constraint retros_has_content check (
    loved    is not null
    or annoyed  is not null
    or learned  is not null
    or next_try is not null
  );

commit;


-- ============================================================
-- SECTION 4: Realtime publication (verify, don't blindly run)
--
-- Realtime v2 respects RLS, so the existing votes-changes and
-- admin-votes channels keep working. Confirm sprints + votes
-- are in the publication before running the ALTER below.
--
-- In Dashboard: Database -> Replication -> supabase_realtime.
-- If sprints or votes is missing, run:
--
--   alter publication supabase_realtime add table public.votes, public.sprints;
-- ============================================================
