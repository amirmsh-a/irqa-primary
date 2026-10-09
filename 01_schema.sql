-- =====================================================================
-- الزيارات الصفية — مخطط قاعدة البيانات (Supabase / PostgreSQL)
-- شغّل هذا الملف مرة واحدة من SQL Editor، ثم شغّل 02_seed.sql
-- =====================================================================

create extension if not exists pgcrypto;

do $$ begin
  create type public.user_role as enum ('admin', 'observer', 'teacher');
exception when duplicate_object then null; end $$;

-- ---------- الجداول ----------

create table if not exists public.settings (
  id        smallint primary key default 1 check (id = 1),
  school    text not null default '',
  year      text not null default '',
  observer  text not null default ''
);

create table if not exists public.subjects (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  sort_order int  not null default 0
);

create table if not exists public.classes (
  id         uuid primary key default gen_random_uuid(),
  grade      text not null,
  section    text not null,
  name       text not null unique,          -- «خامس ثالث»
  sort_order int  not null default 0
);

create table if not exists public.teachers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  subject_id uuid references public.subjects(id) on delete set null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.criteria (
  id          uuid primary key default gen_random_uuid(),
  domain      smallint not null check (domain between 1 and 3),
  sort_order  int  not null,
  letter      text not null,
  title       text not null,
  description text not null default '',
  weight      numeric(5,2) not null check (weight >= 0),
  unique (domain, sort_order)
);

create table if not exists public.visits (
  id                 uuid primary key default gen_random_uuid(),
  teacher_id         uuid not null references public.teachers(id) on delete restrict,
  visit_number       smallint not null check (visit_number in (1, 2)),
  visit_date         date not null,
  subject_id         uuid references public.subjects(id) on delete set null,
  class_id           uuid references public.classes(id) on delete set null,
  period             smallint check (period between 1 and 10),
  observer_name      text not null default '',
  observer_feedback  text not null default '',
  teacher_reflection text not null default '',
  created_by         uuid default auth.uid(),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  -- لا تتكرر الزيارة نفسها للمعلم نفسه
  constraint visits_teacher_visit_unique unique (teacher_id, visit_number)
);

create table if not exists public.visit_scores (
  visit_id     uuid not null references public.visits(id) on delete cascade,
  criterion_id uuid not null references public.criteria(id) on delete restrict,
  score        smallint not null check (score between 0 and 4),
  weight       numeric(5,2) not null,       -- نسخة الوزن وقت الزيارة
  primary key (visit_id, criterion_id)
);

create table if not exists public.schedule (
  teacher_id  uuid primary key references public.teachers(id) on delete cascade,
  specialty   text not null default '',
  status      text not null default 'في الموعد' check (status in ('في الموعد', 'تعديل')),
  v1_week     text not null default '',
  v1_date     date,
  v1_period   smallint,
  v1_class_id uuid references public.classes(id) on delete set null,
  v2_week     text not null default '',
  v2_date     date,
  v2_period   smallint,
  v2_class_id uuid references public.classes(id) on delete set null
);

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  full_name  text not null default '',
  role       public.user_role not null,
  teacher_id uuid references public.teachers(id) on delete set null,
  created_at timestamptz not null default now()
);

-- دعوات المستخدمين: يحدد المدير البريد والدور قبل إنشاء الحساب
create table if not exists public.user_invites (
  email      text primary key,
  full_name  text not null default '',
  role       public.user_role not null,
  teacher_id uuid references public.teachers(id) on delete cascade
);

-- ---------- دوال مساعدة للصلاحيات ----------

create or replace function public.my_role() returns public.user_role
language sql stable security definer set search_path = public as
$$ select role from public.profiles where id = auth.uid() $$;

create or replace function public.my_teacher_id() returns uuid
language sql stable security definer set search_path = public as
$$ select teacher_id from public.profiles where id = auth.uid() $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select role = 'admin' from public.profiles where id = auth.uid()), false) $$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select role in ('admin', 'observer') from public.profiles where id = auth.uid()), false) $$;

-- هل يوجد مدير للنظام؟ (تستخدمها صفحة الدخول عند أول تشغيل)
create or replace function public.has_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.profiles where role = 'admin') $$;

-- ---------- إنشاء الملف الشخصي عند تسجيل مستخدم جديد ----------
-- أول مستخدم يسجَّل يصبح مديراً للنظام. بعد ذلك لا يحصل أي حساب على صلاحية
-- إلا إذا أضاف المدير بريده في user_invites مسبقاً.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  inv public.user_invites%rowtype;
begin
  select * into inv from public.user_invites where lower(email) = lower(new.email);
  if found then
    insert into public.profiles (id, email, full_name, role, teacher_id)
    values (new.id, new.email, inv.full_name, inv.role, inv.teacher_id);
    delete from public.user_invites where email = inv.email;
  elsif not exists (select 1 from public.profiles where role = 'admin') then
    insert into public.profiles (id, email, full_name, role)
    values (new.id, new.email, coalesce(new.raw_user_meta_data ->> 'full_name', new.email), 'admin');
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- updated_at ----------
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

drop trigger if exists visits_touch on public.visits;
create trigger visits_touch before update on public.visits
  for each row execute function public.touch_updated_at();

-- ---------- حفظ زيارة مع درجاتها في عملية واحدة ----------
create or replace function public.save_visit(p jsonb) returns uuid
language plpgsql security invoker set search_path = public as $$
declare
  v_id uuid := coalesce(nullif(p ->> 'id', '')::uuid, gen_random_uuid());
begin
  if jsonb_array_length(coalesce(p -> 'scores', '[]'::jsonb)) = 0 then
    raise exception 'لا توجد درجات في الزيارة';
  end if;

  insert into public.visits as v
    (id, teacher_id, visit_number, visit_date, subject_id, class_id, period,
     observer_name, observer_feedback, teacher_reflection)
  values
    (v_id,
     (p ->> 'teacher_id')::uuid,
     (p ->> 'visit_number')::smallint,
     (p ->> 'visit_date')::date,
     nullif(p ->> 'subject_id', '')::uuid,
     nullif(p ->> 'class_id', '')::uuid,
     nullif(p ->> 'period', '')::smallint,
     coalesce(p ->> 'observer_name', ''),
     coalesce(p ->> 'observer_feedback', ''),
     coalesce(p ->> 'teacher_reflection', ''))
  on conflict (id) do update set
     teacher_id         = excluded.teacher_id,
     visit_number       = excluded.visit_number,
     visit_date         = excluded.visit_date,
     subject_id         = excluded.subject_id,
     class_id           = excluded.class_id,
     period             = excluded.period,
     observer_name      = excluded.observer_name,
     observer_feedback  = excluded.observer_feedback,
     teacher_reflection = excluded.teacher_reflection;

  delete from public.visit_scores where visit_id = v_id;
  insert into public.visit_scores (visit_id, criterion_id, score, weight)
  select v_id, (s ->> 'criterion_id')::uuid, (s ->> 'score')::smallint, (s ->> 'weight')::numeric
  from jsonb_array_elements(p -> 'scores') as s;

  return v_id;
end $$;

-- ---------- المعلم يكتب تأملاته فقط ----------
create or replace function public.set_teacher_reflection(p_visit uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.visits
     set teacher_reflection = coalesce(p_text, '')
   where id = p_visit
     and (public.is_staff() or teacher_id = public.my_teacher_id());
  if not found then
    raise exception 'غير مصرح بتعديل هذه الزيارة';
  end if;
end $$;

-- ---------- Row Level Security ----------
alter table public.settings     enable row level security;
alter table public.subjects     enable row level security;
alter table public.classes      enable row level security;
alter table public.teachers     enable row level security;
alter table public.criteria     enable row level security;
alter table public.visits       enable row level security;
alter table public.visit_scores enable row level security;
alter table public.schedule     enable row level security;
alter table public.profiles     enable row level security;
alter table public.user_invites enable row level security;

-- القوائم المرجعية: قراءة لكل مستخدم له دور، وتعديل للمدير
do $$
declare t text;
begin
  foreach t in array array['settings', 'subjects', 'classes', 'criteria'] loop
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.my_role() is not null)', t || '_read', t);
    execute format('drop policy if exists %I on public.%I', t || '_admin', t);
    execute format('create policy %I on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t || '_admin', t);
  end loop;
end $$;

-- المعلمون: المدير والملاحظ يرون الجميع، والمعلم يرى سجله فقط
drop policy if exists teachers_read on public.teachers;
create policy teachers_read on public.teachers for select to authenticated
  using (public.is_staff() or id = public.my_teacher_id());
drop policy if exists teachers_admin on public.teachers;
create policy teachers_admin on public.teachers for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists teachers_staff_update on public.teachers;
create policy teachers_staff_update on public.teachers for update to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- الزيارات: المعلم يقرأ زياراته فقط
drop policy if exists visits_read on public.visits;
create policy visits_read on public.visits for select to authenticated
  using (public.is_staff() or teacher_id = public.my_teacher_id());
drop policy if exists visits_staff on public.visits;
create policy visits_staff on public.visits for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

drop policy if exists scores_read on public.visit_scores;
create policy scores_read on public.visit_scores for select to authenticated
  using (exists (select 1 from public.visits v where v.id = visit_id));
drop policy if exists scores_staff on public.visit_scores;
create policy scores_staff on public.visit_scores for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- الخطة
drop policy if exists schedule_read on public.schedule;
create policy schedule_read on public.schedule for select to authenticated
  using (public.is_staff() or teacher_id = public.my_teacher_id());
drop policy if exists schedule_staff on public.schedule;
create policy schedule_staff on public.schedule for all to authenticated
  using (public.is_staff()) with check (public.is_staff());

-- المستخدمون
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_admin_update on public.profiles;
create policy profiles_admin_update on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
drop policy if exists profiles_admin_delete on public.profiles;
create policy profiles_admin_delete on public.profiles for delete to authenticated
  using (public.is_admin());

drop policy if exists invites_admin on public.user_invites;
create policy invites_admin on public.user_invites for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- ---------- الصلاحيات ----------
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
revoke all on all tables in schema public from anon;
grant execute on function public.has_admin() to anon, authenticated;
grant execute on function public.save_visit(jsonb) to authenticated;
grant execute on function public.set_teacher_reflection(uuid, text) to authenticated;
revoke execute on function public.save_visit(jsonb) from anon, public;
revoke execute on function public.set_teacher_reflection(uuid, text) from anon, public;
