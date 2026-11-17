-- 배드민턴 경기 잡기 - Supabase 스키마
-- Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run 하세요. (여러 번 실행해도 안전)

create table if not exists public.players (
  name       text primary key check (char_length(name) between 1 and 12),
  level      text not null check (level in ('S','A','B','C','D','초심')),
  gender     text check (gender in ('남','여')),
  updated_at timestamptz not null default now()
);

create table if not exists public.games (
  id         uuid primary key default gen_random_uuid(),
  play_date  date not null,
  play_time  time not null,
  court      text not null,
  level      text check (level in ('S','A','B','C','D','초심')),
  owner      text not null,
  s0 text, s1 text, s2 text, s3 text,
  created_at timestamptz not null default now(),
  -- 같은 날짜·시간·코트에는 경기 하나만
  unique (play_date, play_time, court),
  -- 한 사람이 한 경기에서 두 자리를 잡을 수 없음
  check (
        (s0 is null or s0 not in (coalesce(s1,''), coalesce(s2,''), coalesce(s3,'')))
    and (s1 is null or s1 not in (coalesce(s2,''), coalesce(s3,'')))
    and (s2 is null or s2 is distinct from s3)
  )
);

-- 이미 만든 테이블에 성별 컬럼 추가 (처음 실행이면 아무 일 없음)
alter table public.players add column if not exists gender text check (gender in ('남','여'));

-- 참가자별 통계: 이름, 급수, 성별, 이번 달 참여횟수, 총 참여횟수
-- '참여' = 4명이 다 찬(확정) 경기 중 시작 시간이 지난 경기 (한국 시간 기준)
create or replace view public.player_stats
with (security_invoker = true) as
with played as (
  select g.play_date, x.name
  from public.games g
  cross join lateral (values (g.s0), (g.s1), (g.s2), (g.s3)) as x(name)
  where g.s0 is not null and g.s1 is not null and g.s2 is not null and g.s3 is not null
    and (g.play_date + g.play_time) <= (now() at time zone 'Asia/Seoul')
)
select
  p.name   as 이름,
  p.level  as 급수,
  p.gender as 성별,
  count(pl.name) filter (
    where date_trunc('month', pl.play_date) = date_trunc('month', (now() at time zone 'Asia/Seoul'))
  )::int   as 월_참여횟수,
  count(pl.name)::int as 총_참여횟수
from public.players p
left join played pl on pl.name = p.name
group by p.name, p.level, p.gender;

grant select on public.player_stats to anon, authenticated;

-- 접근 권한: 로그인 없이 이름만 쓰는 앱이라 공개 키(anon)로 읽기/쓰기를 허용합니다.
-- ⚠️ 누구나 데이터를 바꿀 수 있다는 뜻입니다. 진짜 인증을 붙이면 아래 정책을 좁히세요.
alter table public.players enable row level security;
alter table public.games   enable row level security;

grant select, insert, update         on public.players to anon, authenticated;
grant select, insert, update, delete on public.games   to anon, authenticated;

drop policy if exists players_read   on public.players;
drop policy if exists players_insert on public.players;
drop policy if exists players_update on public.players;
create policy players_read   on public.players for select to anon, authenticated using (true);
create policy players_insert on public.players for insert to anon, authenticated with check (true);
create policy players_update on public.players for update to anon, authenticated using (true) with check (true);

drop policy if exists games_read   on public.games;
drop policy if exists games_insert on public.games;
drop policy if exists games_update on public.games;
drop policy if exists games_delete on public.games;
create policy games_read   on public.games for select to anon, authenticated using (true);
create policy games_insert on public.games for insert to anon, authenticated with check (true);
create policy games_update on public.games for update to anon, authenticated using (true) with check (true);
create policy games_delete on public.games for delete to anon, authenticated using (true);

-- 실시간 반영 (다른 사람이 자리를 잡으면 바로 보이게)
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'games') then
    alter publication supabase_realtime add table public.games;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'players') then
    alter publication supabase_realtime add table public.players;
  end if;
end $$;

-- 참가/나가기/삭제를 함수로 처리 (모두 POST 요청이라 PATCH/DELETE를 막는 네트워크에서도 동작)
create or replace function public.join_game(p_id uuid, p_slot int, p_name text)
returns boolean language plpgsql as $$
declare n int;
begin
  if p_slot is null or p_slot not between 0 and 3 then
    raise exception 'invalid slot %', p_slot;
  end if;
  -- 비어 있을 때만 잡기 → 동시에 눌러도 한 명만 성공
  execute format('update public.games set s%s = $1 where id = $2 and s%s is null', p_slot, p_slot)
    using p_name, p_id;
  get diagnostics n = row_count;
  return n > 0;
end $$;

create or replace function public.leave_game(p_id uuid, p_name text)
returns void language sql as $$
  update public.games
     set s0 = nullif(s0, p_name), s1 = nullif(s1, p_name),
         s2 = nullif(s2, p_name), s3 = nullif(s3, p_name)
   where id = p_id;
$$;

create or replace function public.delete_game(p_id uuid, p_name text)
returns void language sql as $$
  delete from public.games where id = p_id and owner = p_name;
$$;

grant execute on function public.join_game(uuid, int, text)  to anon, authenticated;
grant execute on function public.leave_game(uuid, text)      to anon, authenticated;
grant execute on function public.delete_game(uuid, text)     to anon, authenticated;

-- API가 새 함수를 바로 인식하도록
notify pgrst, 'reload schema';
