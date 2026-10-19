-- =====================================================================
-- ESCAPE 10F : 실시간 협동 방탈출 (맵 3종)
-- Supabase SQL Editor에서 이 파일 전체를 실행하세요.
-- 몇 번을 다시 실행해도 안전합니다(기존 랭킹 기록은 지워지지 않음).
-- 기존 아케이드 테이블(scores, hall_of_fame 등)은 건드리지 않습니다.
--
-- 맵: pentacom (PENTACOMM 10F) / lasttrain (LAST TRAIN) / studio (SHOOTING DAY)
-- =====================================================================

-- ---------- 테이블 ----------
create table if not exists escape_rooms (
  code        text primary key,
  host        text not null,
  status      text not null default 'waiting',      -- waiting | playing | cleared | failed
  players     jsonb not null default '[]'::jsonb,   -- [{name, team}]
  roles       jsonb not null default '{}'::jsonb,   -- {name: ["A","C"]}
  solved      jsonb not null default '[]'::jsonb,
  inventory   jsonb not null default '[]'::jsonb,   -- [{puzzle, title, text, by}]
  hints_used  int   not null default 0,
  hint_log    jsonb not null default '[]'::jsonb,
  sync        jsonb not null default '{}'::jsonb,   -- 동시 태그용 {name: epoch}
  started_at  timestamptz,
  ended_at    timestamptz,
  created_at  timestamptz not null default now()
);
alter table escape_rooms add column if not exists map text not null default 'pentacom';

-- 정답과 단서 원본: 클라이언트가 직접 읽을 수 없음 (RLS 정책 없음)
create table if not exists escape_secrets (
  code     text primary key references escape_rooms(code) on delete cascade,
  data     jsonb not null,
  answers  jsonb not null
);

create table if not exists escape_records (
  id          bigserial primary key,
  code        text,
  players     jsonb not null,
  clear_secs  int not null,
  hints       int not null default 0,
  total_secs  int not null,            -- clear_secs + hints * 120
  created_at  timestamptz not null default now()
);
alter table escape_records add column if not exists map text not null default 'pentacom';
create index if not exists escape_records_total_idx on escape_records (total_secs);
create index if not exists escape_records_map_idx on escape_records (map, total_secs);

alter table escape_rooms   enable row level security;
alter table escape_secrets enable row level security;
alter table escape_records enable row level security;

drop policy if exists escape_rooms_read   on escape_rooms;
drop policy if exists escape_records_read on escape_records;
create policy escape_rooms_read   on escape_rooms   for select using (true);
create policy escape_records_read on escape_records for select using (true);

-- ---------- 이전 버전 함수 정리 ----------
drop function if exists _esc_generate();
drop function if exists _esc_reward(text, jsonb);
drop function if exists _esc_prereq(text);
drop function if exists escape_create_room(text, text);

-- ---------- 공통 유틸 ----------
create or replace function _esc_rand(n int) returns int
language sql volatile as $$ select floor(random() * n)::int $$;

create or replace function _esc_shuffle(arr text[]) returns text[]
language sql volatile as $$
  select coalesce(array_agg(x order by random()), array[]::text[]) from unnest(arr) x;
$$;

create or replace function _esc_norm(s text) returns text
language sql immutable as $$
  select upper(regexp_replace(coalesce(s, ''), '[\s_\-\.,원]', '', 'g'));
$$;

create or replace function _esc_txt(j jsonb) returns text[]
language sql immutable as $$
  select coalesce(array_agg(x order by o), array[]::text[]) from jsonb_array_elements_text(j) with ordinality t(x, o);
$$;

-- =====================================================================
-- 맵 정의
--   m    : 퍼즐 메커닉 (아래 _esc_mech 참고)
--   pair : [a 단서를 보는 역할, b 단서를 보는 역할]  (짝은 항상 서로 다른 사람이 되도록 A-B, A-D, B-C, C-D 만 사용)
--   pre  : 먼저 풀려 있어야 하는 퍼즐
--   r    : 풀었을 때 공유 아이템 ({w1}{w2}{w3} = 최종 퍼즐 단어)
-- =====================================================================
create or replace function _esc_def(p_map text) returns jsonb
language sql immutable as $$
select case p_map
-- ---------------------------------------------------------------- PENTACOMM 10F
when 'pentacom' then $j${
  "limit": 40, "final": "filename",
  "puzzles": {
    "calendar": {"m":"pick","pair":["A","B"],"pre":[],
      "p":{"labels":["빨강","파랑","초록"],"min":1,"max":31,"pad":2},
      "r":{"title":"서랍 속 메모","text":"\"27번 자리 모니터 잠금 패턴은 포스트잇에 적어뒀음 - 스튜디오 새폴더\""}},
    "receipt": {"m":"sum","pair":["A","D"],"pre":[],
      "p":{"menu":["김밥","라면","떡볶이","순대","튀김","쫄면","만두","어묵"],"pmin":4,"pmax":12,"step":500,"picks":4,"qmax":3},
      "r":{"title":"영수증 뒷면","text":"영수증 뒤에 \"자리 배치도는 새폴더 기둥에 붙어 있음\"이라고 적혀 있다."}},
    "pattern": {"m":"pattern","pair":["C","D"],"pre":[],
      "p":{"symbols":["★","●","▲","■","◆","♥","♣","♠","✿"],"len":5},
      "r":{"title":"라운지 출입 카드","text":"모니터 메모장에 \"라운지 문 열어둠. 커피 주문 좀 받아줘\"라고 적혀 있다."}},
    "seatmap": {"m":"walk","pair":["C","B"],"pre":[],
      "p":{"rows":4,"cols":6,"start":27,"steps":4},
      "r":{"title":"비품장 열쇠","text":"그 자리 서랍에서 라운지 비품장 열쇠를 찾았다."}},
    "tiles": {"m":"grid","pair":["C","D"],"pre":["calendar","receipt","pattern","seatmap"],
      "p":{"rows":5,"cols":7,"k":3},
      "r":{"title":"파일명 조각 ①","text":"PT 파일명 1번째 단어: {w1}"}},
    "coffee": {"m":"order","pair":["ALL"],"pre":["calendar","receipt","pattern","seatmap"],
      "p":{"items":["아메리카노","카페라떼","바닐라라떼","콜드브루"],"who":["김대리","박과장","이주임","최팀장"],"hour":"22"},
      "r":{"title":"회의실 카드키","text":"커피머신 아래에서 회의실 카드키가 나왔다."}},
    "shelf": {"m":"formula","pair":["C","B"],"pre":["calendar","receipt","pattern","seatmap"],
      "p":{"items":["머그컵","찻잔","티팟","유리병"],"max":6},
      "r":{"title":"비품장 쪽지","text":"\"회의실 조명 번호표는 경영지원팀이 갖고 있음\""}},
    "chart": {"m":"chart","pair":["A","B"],"pre":["tiles","coffee","shelf"],
      "p":{"labels":["4월","5월","6월","7월","8월","9월"],"min":20,"max":95},
      "r":{"title":"파일명 조각 ②","text":"PT 파일명 2번째 단어: {w2}"}},
    "white": {"m":"textdiff","pair":["A","B"],"pre":["tiles","coffee","shelf"],
      "p":{"sources":["오늘의 한 끼가 내일의 나를 만든다","작은 습관이 모여 큰 변화를 만든다","매일 쓰는 것에 가장 좋은 것을 담다","좋은 생각은 늘 가까이에 있다","당신의 하루를 조금 더 가볍게 만든다","평범한 순간을 특별하게 기억하다"],
           "words":["탈출성공","야근금지","칼퇴하자","광고천재","새벽세시","회식취소","PT대박나","퇴근시켜"]},
      "r":{"title":"USB 보관함 위치","text":"화이트보드 구석에 \"USB는 포커스 부스 사물함에\"라는 낙서가 있다."}},
    "lights": {"m":"lights","pair":["A","D"],"pre":["tiles","coffee","shelf"],
      "p":{"names":["창가","복도","TV","화이트보드","출입문","천장"]},
      "r":{"title":"회의실 조명","text":"조명이 켜지자 TV 옆에 붙은 포스트잇이 보인다: \"차트 숫자 하나 틀림!\""}},
    "stripes": {"m":"count","pair":["C","D"],"pre":["tiles","coffee","shelf"],
      "p":{"colors":["빨강","남색","회색"],"targets":["빨강","남색"],"groups":4,"len":7},
      "r":{"title":"파일명 조각 ③ + USB","text":"사물함에서 USB를 찾았다! 라벨: 파일명 3번째 단어 {w3}."}},
    "notebook": {"m":"notebook","pair":["A","B"],"pre":["tiles","coffee","shelf"],
      "p":{"words":["칼퇴만세","월급루팡","기획대박","컨펌완료","회의끝남","카피장인","보고완료","점심뭐먹"],"lines":5,"len":5},
      "r":{"title":"노트 속 메모","text":"\"PT 파일명은 회사 슬로건 세 단어로. 순서는 USB 라벨 참고\""}},
    "filename": {"m":"final","pair":["ALL"],"pre":["chart","white","lights","stripes","notebook"],
      "p":{"words":["Deeply","Differently","Detail"]},
      "r":{"title":"PT 파일 확인","text":"파일이 열렸다. 이제 두 사람이 동시에 출입 단말기에 카드를 태그하면 탈출!"}}
  }}$j$::jsonb

-- ---------------------------------------------------------------- LAST TRAIN (쉬움)
when 'lasttrain' then $j${
  "limit": 25, "final": "exitpath",
  "puzzles": {
    "board": {"m":"pick","pair":["A","B"],"pre":[],
      "p":{"labels":["장암행","석남행","왕십리행","인천행"],"k":3,"min":1,"max":9,"pad":1},
      "r":{"title":"비상문 열쇠","text":"승강장 비상문이 열렸다. 객차 안으로 들어갈 수 있다."}},
    "locker": {"m":"walk","pair":["C","B"],"pre":[],
      "p":{"rows":4,"cols":5,"start":24,"steps":3},
      "r":{"title":"보관함 속 가방","text":"가방 안에 \"역무실 비밀번호는 무전 순서대로\"라고 적힌 쪽지가 있다."}},
    "card": {"m":"sum","pair":["A","D"],"pre":[],
      "p":{"menu":["지하철","간선버스","지선버스","마을버스","광역버스","심야버스","공항철도","신분당선"],"pmin":12,"pmax":30,"step":100,"picks":3,"qmax":3},
      "r":{"title":"충전된 교통카드","text":"잔액이 맞춰지자 교통카드가 인식된다. 나중에 개찰구에서 쓸 수 있다."}},
    "lost": {"m":"formula","pair":["C","B"],"pre":[],
      "p":{"items":["우산","모자","장갑","목도리"],"max":6},
      "r":{"title":"역무실 카드키","text":"분실물 상자 바닥에서 역무실 카드키가 나왔다."}},
    "cctv": {"m":"grid","pair":["C","D"],"pre":["board","locker","card","lost"],
      "p":{"rows":3,"cols":4,"k":3},
      "r":{"title":"탈출 경로 ①","text":"CCTV에 찍힌 순찰 경로 1번째: {w1}"}},
    "radio": {"m":"order","pair":["ALL"],"pre":["board","locker","card","lost"],
      "p":{"items":["승강장","대합실","환승통로","출구"],"who":["역무원 김","역무원 박","공익 이","미화 최"],"hour":"00"},
      "r":{"title":"탈출 경로 ②","text":"무전 기록에 남은 순찰 경로 2번째: {w2}"}},
    "keybox": {"m":"notebook","pair":["A","B"],"pre":["board","locker","card","lost"],
      "p":{"words":["첫차대기","막차놓침","택시잡자","집에가자","환승실패","내일출근","졸다깼다","종점도착"],"lines":5,"len":5},
      "r":{"title":"탈출 경로 ③","text":"열쇠함 안쪽 메모에 적힌 순찰 경로 3번째: {w3}"}},
    "exitpath": {"m":"final","pair":["ALL"],"pre":["cctv","radio","keybox"],
      "p":{"words":["계단","개찰구","4번출구"]},
      "r":{"title":"비상 게이트 활성화","text":"경로가 확인됐다. 두 사람이 동시에 개찰구에 교통카드를 찍으면 탈출!"}}
  }}$j$::jsonb

-- ---------------------------------------------------------------- SHOOTING DAY (어려움)
when 'studio' then $j${
  "limit": 45, "final": "action",
  "puzzles": {
    "tape": {"m":"pick","pair":["A","B"],"pre":[],
      "p":{"labels":["노랑","빨강","파랑","초록"],"k":3,"min":10,"max":99,"pad":2},
      "r":{"title":"분장실 열쇠","text":"슬레이트 안쪽에 테이프로 붙여둔 분장실 열쇠를 찾았다."}},
    "conti": {"m":"order","pair":["ALL"],"pre":[],
      "p":{"items":["와이드","클로즈업","인서트","엔딩"],"who":["감독","조감독","PD","촬영감독"],"hour":"03"},
      "r":{"title":"콘티북","text":"콘티 순서가 맞춰지자 콘티북 뒤에서 장비실 출입 카드가 떨어졌다."}},
    "mirror": {"m":"pattern","pair":["C","D"],"pre":[],
      "p":{"symbols":["★","☾","❀","♛","✦","☂","♪","◆","♥"],"len":6},
      "r":{"title":"화장대 서랍","text":"서랍 안에 \"편집실 비번은 감독님만 앎\"이라는 메모가 있다."}},
    "makeup": {"m":"formula","pair":["C","B"],"pre":[],
      "p":{"items":["립스틱","브러시","퍼프","헤어핀"],"max":7},
      "r":{"title":"분장 키트","text":"분장 키트 안에서 편집실 리모컨을 찾았다."}},
    "callsheet": {"m":"notebook","pair":["A","B"],"pre":[],
      "p":{"words":["컷오케이","한번더요","슛들어감","엔지났다","풀샷가요","리허설중","조명체크","모니터링"],"lines":6,"len":6},
      "r":{"title":"콜시트 메모","text":"\"장비실 렌즈는 촬영감독님 메모대로 옮겨놨음\""}},
    "gel": {"m":"lights","pair":["A","D"],"pre":["tape","conti","mirror","makeup","callsheet"],
      "p":{"names":["키라이트","필라이트","백라이트","탑라이트","배경등","효과등"]},
      "r":{"title":"조명 콘솔","text":"조명이 들어오자 장비실 구석의 렌즈 케이스가 보인다."}},
    "cases": {"m":"grid","pair":["C","D"],"pre":["tape","conti","mirror","makeup","callsheet"],
      "p":{"rows":5,"cols":8,"k":4},
      "r":{"title":"구호 카드 ③","text":"빨간 태그 케이스 속 카드: 3번째 구호 {w3}"}},
    "lens": {"m":"walk","pair":["C","B"],"pre":["tape","conti","mirror","makeup","callsheet"],
      "p":{"rows":4,"cols":6,"start":35,"steps":5},
      "r":{"title":"렌즈 케이스","text":"케이스 안 메모: \"편집본 길이가 콘티랑 다르면 감독님 화나심\""}},
    "timeline": {"m":"chart","pair":["A","B"],"pre":["tape","conti","mirror","makeup","callsheet"],
      "p":{"labels":["C#1","C#2","C#3","C#4","C#5","C#6"],"min":3,"max":30},
      "r":{"title":"구호 카드 ①","text":"타임라인 끝 마커에 적힌 1번째 구호: {w1}"}},
    "subtitle": {"m":"textdiff","pair":["C","B"],"pre":["tape","conti","mirror","makeup","callsheet"],
      "p":{"sources":["한 번의 장면이 오래 기억된다","당신의 아침을 더 밝게 비춘다","가장 가까운 곳에서 시작된다","작은 차이가 큰 장면을 만든다","오늘을 기록하는 가장 쉬운 방법"],
           "words":["밤샘촬영","컷오케이","감독최고","슛들어감","새벽다섯","커피수혈","엔지금지","촬영종료"]},
      "r":{"title":"구호 카드 ②","text":"최종 자막 파일 이름에 숨어 있던 2번째 구호: {w2}"}},
    "action": {"m":"final","pair":["ALL"],"pre":["gel","cases","lens","timeline","subtitle"],
      "p":{"words":["LIGHTS","CAMERA","ACTION"]},
      "r":{"title":"방음문 잠금 해제 준비","text":"구호가 입력됐다. 두 사람이 동시에 비상 해제 버튼을 누르면 탈출!"}}
  }}$j$::jsonb
else null end;
$$;

-- =====================================================================
-- 퍼즐 메커닉: 랜덤 단서 생성 → {a, b, orders, pub, ans}
-- =====================================================================
create or replace function _esc_mech(m text, p jsonb) returns jsonb
language plpgsql volatile as $$
declare
  labels text[]; vals int[]; ord text[]; ans text := ''; obj jsonb := '{}'::jsonb;
  k int; lo int; hi int; padn int; n int; i int; j int; cnt int;
  syms text[]; seq int[]; seqs jsonb;
  rows_ int; cols_ int; odd int[]; digits int[];
  items text[]; who text[]; mins int[]; orders jsonb := '[]'::jsonb; roles text[] := array['A','B','C','D'];
  tbl int[]; chart_ int[]; wrong int; delta int;
  srcs text[]; words text[]; src text; word text; chars text[]; wchars text[]; cand int[]; pos int[]; modc text[]; ok boolean; tries int := 0;
  colors text[]; groups jsonb := '[]'::jsonb; grp text[]; target text; gorder text[];
  menu text[]; prices int[]; idx int[]; picks jsonb := '[]'::jsonb; q int; total int := 0;
  nums int[]; startn int; spos int; r int; c int; nr int; nc int; moves text[]; dir text; steps int;
  counts int[]; f text[];
  lnums int[]; lon boolean[]; lorder int[];
  pool text[] := regexp_split_to_array('가나다라마바사아자차카타파하고노도로모보소오조초코토포호구누두루무부수우주추쿠투푸후기니디리미비시이지치키티피히', '');
  nl int[]; np int[]; marks text[] := array[]::text[]; line text[]; lines jsonb := '[]'::jsonb; nlines int; llen int;
begin
  -- 1) pick: a=라벨별 숫자, b=읽을 순서 → 숫자를 순서대로 이어 붙임
  if m = 'pick' then
    labels := _esc_txt(p->'labels'); n := array_length(labels, 1);
    k := coalesce((p->>'k')::int, n); lo := coalesce((p->>'min')::int, 1);
    hi := coalesce((p->>'max')::int, 31); padn := coalesce((p->>'pad')::int, 2);
    select array_agg(d) into vals from (select d from generate_series(lo, hi) d order by random() limit n) s;
    ord := (_esc_shuffle(labels))[1:k];
    for i in 1..k loop ans := ans || lpad(vals[array_position(labels, ord[i])]::text, padn, '0'); end loop;
    for i in 1..n loop obj := obj || jsonb_build_object(labels[i], vals[i]); end loop;
    return jsonb_build_object('a', jsonb_build_object('values', obj), 'b', jsonb_build_object('order', to_jsonb(ord)), 'ans', ans);

  -- 2) pattern: a=점마다 기호, b=기호 순서 → 점 번호 순서
  elsif m = 'pattern' then
    syms := _esc_shuffle(_esc_txt(p->'symbols')); n := coalesce((p->>'len')::int, 5);
    select array_agg(d) into seq from (select d from generate_series(0, 8) d order by random() limit n) s;
    select jsonb_agg(syms[x + 1] order by o) into seqs from unnest(seq) with ordinality t(x, o);
    return jsonb_build_object('a', jsonb_build_object('symbols', to_jsonb(syms)), 'b', jsonb_build_object('seq', seqs),
                              'ans', array_to_string(seq, ''));

  -- 3) grid: a=눈에 띄는 칸 위치, b=칸별 숫자 → 해당 칸 숫자(위→아래, 왼→오)
  elsif m = 'grid' then
    rows_ := (p->>'rows')::int; cols_ := (p->>'cols')::int; k := (p->>'k')::int;
    select array_agg(d order by d) into odd from (select d from generate_series(0, rows_ * cols_ - 1) d order by random() limit k) s;
    select array_agg(_esc_rand(10)) into digits from generate_series(1, rows_ * cols_);
    for i in 1..k loop ans := ans || digits[odd[i] + 1]::text; end loop;
    return jsonb_build_object('a', jsonb_build_object('rows', rows_, 'cols', cols_, 'odd', to_jsonb(odd)),
                              'b', jsonb_build_object('rows', rows_, 'cols', cols_, 'digits', to_jsonb(digits)), 'ans', ans);

  -- 4) order: 역할마다 메시지 하나 → 시간순으로 항목 버튼
  elsif m = 'order' then
    items := _esc_txt(p->'items'); ord := _esc_shuffle(items); who := _esc_shuffle(_esc_txt(p->'who'));
    select array_agg(d) into mins from (select d from generate_series(0, 59) d order by random() limit 4) s;
    for i in 1..4 loop
      orders := orders || jsonb_build_array(jsonb_build_object('role', roles[i], 'who', who[i], 'item', ord[i],
        'time', (p->>'hour') || ':' || lpad(mins[i]::text, 2, '0'), 'min', mins[i]));
    end loop;
    select string_agg((array_position(items, e->>'item') - 1)::text, '' order by (e->>'min')::int) into ans
      from jsonb_array_elements(orders) e;
    return jsonb_build_object('orders', orders, 'ans', ans);

  -- 5) chart: a=그래프 값(하나 틀림), b=원본 표 → 틀린 항목의 원본 값
  elsif m = 'chart' then
    labels := _esc_txt(p->'labels'); n := array_length(labels, 1);
    lo := (p->>'min')::int; hi := (p->>'max')::int;
    select array_agg(lo + _esc_rand(hi - lo + 1)) into tbl from generate_series(1, n);
    chart_ := tbl; wrong := 1 + _esc_rand(n);
    delta := greatest(2, (hi - lo) / 6 + _esc_rand(greatest(1, (hi - lo) / 5))) * (case when random() < 0.5 then -1 else 1 end);
    chart_[wrong] := tbl[wrong] + delta;
    if chart_[wrong] < 1 or chart_[wrong] > hi + 10 then chart_[wrong] := tbl[wrong] - delta; end if;
    return jsonb_build_object('a', jsonb_build_object('labels', to_jsonb(labels), 'values', to_jsonb(chart_)),
                              'b', jsonb_build_object('labels', to_jsonb(labels), 'values', to_jsonb(tbl)), 'ans', tbl[wrong]::text);

  -- 6) textdiff: a=바뀐 문장, b=원본 → 바뀐 글자를 이어 붙인 단어
  elsif m = 'textdiff' then
    srcs := _esc_txt(p->'sources'); words := _esc_txt(p->'words');
    loop
      tries := tries + 1;
      src := srcs[1 + _esc_rand(array_length(srcs, 1))]; word := words[1 + _esc_rand(array_length(words, 1))];
      chars := regexp_split_to_array(src, ''); wchars := regexp_split_to_array(word, '');
      select array_agg(x) into cand from generate_series(1, array_length(chars, 1)) x where chars[x] <> ' ';
      select array_agg(x order by x) into pos from (select x from unnest(cand) x order by random() limit array_length(wchars, 1)) s;
      ok := true;
      for i in 1..array_length(wchars, 1) loop if chars[pos[i]] = wchars[i] then ok := false; end if; end loop;
      exit when ok or tries > 50;
    end loop;
    modc := chars;
    for i in 1..array_length(wchars, 1) loop modc[pos[i]] := wchars[i]; end loop;
    return jsonb_build_object('a', jsonb_build_object('text', array_to_string(modc, '')),
                              'b', jsonb_build_object('text', src), 'ans', word);

  -- 7) count: a=그룹별 색 줄, b=세는 색과 순서 → 그룹별 개수
  elsif m = 'count' then
    colors := _esc_txt(p->'colors'); n := (p->>'groups')::int; k := (p->>'len')::int;
    for i in 1..n loop
      select array_agg(colors[1 + _esc_rand(array_length(colors, 1))]) into grp from generate_series(1, k);
      groups := groups || jsonb_build_array(to_jsonb(grp));
    end loop;
    target := (_esc_txt(p->'targets'))[1 + _esc_rand(jsonb_array_length(p->'targets'))];
    select array_agg(x::text order by random()) into gorder from generate_series(1, n) x;
    for i in 1..n loop
      select count(*) into cnt from jsonb_array_elements_text(groups -> (gorder[i]::int - 1)) e where e = target;
      ans := ans || cnt::text;
    end loop;
    return jsonb_build_object('a', jsonb_build_object('groups', groups),
                              'b', jsonb_build_object('color', target, 'order', to_jsonb(gorder)), 'ans', ans);

  -- 8) sum: a=품목과 수량, b=가격표 → 합계
  elsif m = 'sum' then
    menu := _esc_txt(p->'menu'); n := array_length(menu, 1);
    select array_agg(((p->>'pmin')::int + _esc_rand((p->>'pmax')::int - (p->>'pmin')::int + 1)) * (p->>'step')::int)
      into prices from generate_series(1, n);
    select array_agg(d) into idx from (select d from generate_series(1, n) d order by random() limit (p->>'picks')::int) s;
    for i in 1..array_length(idx, 1) loop
      q := 1 + _esc_rand((p->>'qmax')::int);
      picks := picks || jsonb_build_array(jsonb_build_object('name', menu[idx[i]], 'qty', q));
      total := total + q * prices[idx[i]];
    end loop;
    return jsonb_build_object('a', jsonb_build_object('items', picks),
                              'b', jsonb_build_object('menu', to_jsonb(menu), 'prices', to_jsonb(prices)), 'ans', total::text);

  -- 9) walk: a=번호 배치도, b=출발 번호와 이동 방향 → 도착 번호
  elsif m = 'walk' then
    rows_ := (p->>'rows')::int; cols_ := (p->>'cols')::int; startn := (p->>'start')::int; steps := (p->>'steps')::int;
    select array_agg(d) into nums
      from (select d from generate_series(11, 99) d where d <> startn order by random() limit rows_ * cols_ - 1) s;
    nums := nums || startn;
    select array_agg(x order by random()) into nums from unnest(nums) x;
    spos := array_position(nums, startn) - 1;
    loop
      r := spos / cols_; c := spos % cols_; moves := array[]::text[];
      for i in 1..steps loop
        loop
          dir := (array['↑','↓','←','→'])[1 + _esc_rand(4)];
          nr := r + case dir when '↑' then -1 when '↓' then 1 else 0 end;
          nc := c + case dir when '←' then -1 when '→' then 1 else 0 end;
          exit when nr between 0 and rows_ - 1 and nc between 0 and cols_ - 1;
        end loop;
        r := nr; c := nc; moves := moves || dir;
      end loop;
      exit when r * cols_ + c <> spos;
    end loop;
    return jsonb_build_object('a', jsonb_build_object('rows', rows_, 'cols', cols_, 'nums', to_jsonb(nums)),
                              'b', jsonb_build_object('start', startn, 'moves', to_jsonb(moves)), 'ans', nums[r * cols_ + c + 1]::text);

  -- 10) formula: a=물건 개수, b=(x × y) + z → 계산값
  elsif m = 'formula' then
    items := _esc_txt(p->'items');
    select array_agg(1 + _esc_rand((p->>'max')::int)) into counts from generate_series(1, array_length(items, 1));
    f := (_esc_shuffle(items))[1:3];
    return jsonb_build_object('a', jsonb_build_object('items', to_jsonb(items), 'counts', to_jsonb(counts)),
                              'b', jsonb_build_object('formula', to_jsonb(f)),
                              'ans', (counts[array_position(items, f[1])] * counts[array_position(items, f[2])]
                                      + counts[array_position(items, f[3])])::text);

  -- 11) lights: a=켜진 스위치, b=스위치 번호 → 켜진 번호 작은 수부터
  elsif m = 'lights' then
    labels := _esc_txt(p->'names'); n := array_length(labels, 1);
    select array_agg(d) into lnums from (select d from generate_series(1, 9) d order by random() limit n) s;
    k := 2 + _esc_rand(3);
    select array_agg(d) into lorder from (select d from generate_series(1, n) d order by random() limit k) s;
    select array_agg(g.x = any(lorder) order by g.x) into lon from generate_series(1, n) as g(x);
    select string_agg(lnums[u.x]::text, '' order by lnums[u.x]) into ans from unnest(lorder) as u(x);
    return jsonb_build_object('a', jsonb_build_object('names', to_jsonb(labels), 'on', to_jsonb(lon)),
                              'b', jsonb_build_object('names', to_jsonb(labels), 'nums', to_jsonb(lnums)), 'ans', ans);

  -- 12) notebook: a=글자 줄, b="줄-칸" 표시 → 단어
  elsif m = 'notebook' then
    words := _esc_txt(p->'words'); word := words[1 + _esc_rand(array_length(words, 1))];
    wchars := regexp_split_to_array(word, ''); n := array_length(wchars, 1);
    nlines := (p->>'lines')::int; llen := (p->>'len')::int;
    select array_agg(d) into nl from (select d from generate_series(1, nlines) d order by random() limit n) s;
    select array_agg(1 + _esc_rand(llen)) into np from generate_series(1, n);
    for i in 1..nlines loop
      select array_agg(pool[1 + _esc_rand(array_length(pool, 1))]) into line from generate_series(1, llen);
      for j in 1..n loop if nl[j] = i then line[np[j]] := wchars[j]; end if; end loop;
      lines := lines || to_jsonb(array_to_string(line, ''));
    end loop;
    for j in 1..n loop marks := marks || (nl[j]::text || '-' || np[j]::text); end loop;
    return jsonb_build_object('a', jsonb_build_object('lines', lines), 'b', jsonb_build_object('marks', to_jsonb(marks)), 'ans', word);

  -- 13) final: 앞 퍼즐 보상으로 공개되는 단어 순서
  elsif m = 'final' then
    words := _esc_shuffle(_esc_txt(p->'words'));
    return jsonb_build_object('pub', jsonb_build_object('order', to_jsonb(words)), 'ans', array_to_string(words, '_'));
  end if;
  raise exception 'unknown mechanic %', m;
end $$;

create or replace function _esc_generate(p_map text) returns jsonb
language plpgsql volatile as $$
declare def jsonb := _esc_def(p_map); k text; v jsonb; g jsonb; v_data jsonb := '{}'::jsonb; v_ans jsonb := '{}'::jsonb;
begin
  for k, v in select key, value from jsonb_each(def->'puzzles') loop
    g := _esc_mech(v->>'m', v->'p');
    v_data := v_data || jsonb_build_object(k, jsonb_build_object('m', v->>'m', 'pair', v->'pair',
      'a', g->'a', 'b', g->'b', 'orders', g->'orders', 'pub', g->'pub'));
    v_ans := v_ans || jsonb_build_object(k, g->>'ans');
  end loop;
  return jsonb_build_object('data', v_data, 'answers', v_ans);
end $$;

create or replace function _esc_reward(p_map text, p_puzzle text, p_data jsonb) returns jsonb
language plpgsql immutable as $$
declare def jsonb := _esc_def(p_map); r jsonb; w jsonb; t text;
begin
  r := def->'puzzles'->p_puzzle->'r';
  w := p_data->(def->>'final')->'pub'->'order';
  t := replace(replace(replace(r->>'text', '{w1}', w->>0), '{w2}', w->>1), '{w3}', w->>2);
  return jsonb_build_object('title', r->>'title', 'text', t);
end $$;

-- 시간 초과 처리 (맵별 제한 시간)
create or replace function _esc_check_timeout(p_code text) returns boolean
language plpgsql as $$
begin
  update escape_rooms set status = 'failed', ended_at = now()
   where code = p_code and status = 'playing'
     and now() - started_at > make_interval(mins => (_esc_def(map)->>'limit')::int);
  return found;
end $$;

-- =====================================================================
-- RPC
-- =====================================================================
create or replace function escape_create_room(p_name text, p_team text, p_map text default 'pentacom') returns text
language plpgsql security definer set search_path = public as $$
declare v_code text; v_chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; i int;
begin
  p_name := trim(coalesce(p_name, ''));
  if length(p_name) < 1 or length(p_name) > 12 then raise exception '이름은 1~12자로 입력해 주세요'; end if;
  p_map := coalesce(p_map, 'pentacom');
  if _esc_def(p_map) is null then raise exception '알 수 없는 맵이에요'; end if;
  delete from escape_rooms where created_at < now() - interval '1 day';
  loop
    v_code := '';
    for i in 1..4 loop v_code := v_code || substr(v_chars, 1 + _esc_rand(length(v_chars)), 1); end loop;
    exit when not exists (select 1 from escape_rooms where code = v_code);
  end loop;
  insert into escape_rooms (code, host, map, players)
  values (v_code, p_name, p_map, jsonb_build_array(jsonb_build_object('name', p_name, 'team', p_team)));
  return v_code;
end $$;

create or replace function escape_join(p_code text, p_name text, p_team text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r escape_rooms;
begin
  p_name := trim(coalesce(p_name, ''));
  select * into r from escape_rooms where code = upper(trim(p_code)) for update;
  if not found then raise exception '방을 찾을 수 없어요'; end if;
  if exists (select 1 from jsonb_array_elements(r.players) e where e->>'name' = p_name) then
    return jsonb_build_object('ok', true, 'code', r.code);   -- 재접속
  end if;
  if r.status <> 'waiting' then raise exception '이미 시작된 방이에요'; end if;
  if jsonb_array_length(r.players) >= 4 then raise exception '방이 가득 찼어요 (최대 4명)'; end if;
  update escape_rooms
     set players = players || jsonb_build_array(jsonb_build_object('name', p_name, 'team', p_team))
   where code = r.code;
  return jsonb_build_object('ok', true, 'code', r.code);
end $$;

create or replace function escape_leave(p_code text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare r escape_rooms; v_players jsonb;
begin
  select * into r from escape_rooms where code = p_code for update;
  if not found or r.status <> 'waiting' then return; end if;
  select coalesce(jsonb_agg(e), '[]'::jsonb) into v_players
    from jsonb_array_elements(r.players) e where e->>'name' <> p_name;
  if jsonb_array_length(v_players) = 0 then
    delete from escape_rooms where code = p_code;
  else
    update escape_rooms
       set players = v_players, host = case when host = p_name then v_players->0->>'name' else host end
     where code = p_code;
  end if;
end $$;

-- 대기실에서 방장이 맵 변경
create or replace function escape_set_map(p_code text, p_name text, p_map text) returns void
language plpgsql security definer set search_path = public as $$
declare r escape_rooms;
begin
  select * into r from escape_rooms where code = p_code for update;
  if not found then raise exception '방을 찾을 수 없어요'; end if;
  if r.host <> p_name then raise exception '방장만 맵을 바꿀 수 있어요'; end if;
  if r.status <> 'waiting' then raise exception '이미 시작됐어요'; end if;
  if _esc_def(p_map) is null then raise exception '알 수 없는 맵이에요'; end if;
  update escape_rooms set map = p_map where code = p_code;
end $$;

create or replace function escape_start(p_code text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare r escape_rooms; v_names text[]; n int; v_roles jsonb; v_gen jsonb;
begin
  select * into r from escape_rooms where code = p_code for update;
  if not found then raise exception '방을 찾을 수 없어요'; end if;
  if r.host <> p_name then raise exception '방장만 시작할 수 있어요'; end if;
  if r.status <> 'waiting' then raise exception '이미 시작됐어요'; end if;
  n := jsonb_array_length(r.players);
  if n < 2 then raise exception '2명 이상 모여야 시작할 수 있어요'; end if;

  select array_agg(e->>'name' order by random()) into v_names from jsonb_array_elements(r.players) e;
  -- 짝이 되는 역할(A-B, A-D, B-C, C-D)은 항상 다른 사람이 갖도록 배정
  if n = 2 then
    v_roles := jsonb_build_object(v_names[1], jsonb_build_array('A','C'), v_names[2], jsonb_build_array('B','D'));
  elsif n = 3 then
    v_roles := jsonb_build_object(v_names[1], jsonb_build_array('A'), v_names[2], jsonb_build_array('B','D'),
                                  v_names[3], jsonb_build_array('C'));
  else
    v_roles := jsonb_build_object(v_names[1], jsonb_build_array('A'), v_names[2], jsonb_build_array('B'),
                                  v_names[3], jsonb_build_array('C'), v_names[4], jsonb_build_array('D'));
  end if;

  v_gen := _esc_generate(r.map);
  insert into escape_secrets (code, data, answers) values (p_code, v_gen->'data', v_gen->'answers')
  on conflict (code) do update set data = excluded.data, answers = excluded.answers;

  update escape_rooms
     set status = 'playing', roles = v_roles, solved = '[]', inventory = '[]',
         hints_used = 0, hint_log = '[]', sync = '{}', started_at = now(), ended_at = null
   where code = p_code;
end $$;

-- 내 역할에 해당하는 단서만 반환
create or replace function escape_get_clues(p_code text, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r escape_rooms; s escape_secrets; v_my jsonb; out_ jsonb := '{}'::jsonb; k text; v jsonb; o jsonb;
begin
  select * into r from escape_rooms where code = p_code;
  if not found or r.status = 'waiting' then raise exception '진행 중인 게임이 아니에요'; end if;
  v_my := r.roles -> p_name;
  if v_my is null then raise exception '이 방의 참가자가 아니에요'; end if;
  select * into s from escape_secrets where code = p_code;

  for k, v in select key, value from jsonb_each(s.data) loop
    o := '{}'::jsonb;
    if v->>'m' = 'order' then
      o := jsonb_build_object('orders', (select coalesce(jsonb_agg(e - 'min'), '[]'::jsonb)
                                           from jsonb_array_elements(v->'orders') e where v_my ? (e->>'role')));
    elsif v->>'m' <> 'final' then
      if v_my ? (v->'pair'->>0) then o := o || jsonb_build_object('a', v->'a'); end if;
      if v_my ? (v->'pair'->>1) then o := o || jsonb_build_object('b', v->'b'); end if;
    end if;
    out_ := out_ || jsonb_build_object(k, o);
  end loop;
  return jsonb_build_object('map', r.map, 'roles', v_my, 'clues', out_, 'server_now', extract(epoch from now()));
end $$;

create or replace function escape_submit(p_code text, p_name text, p_puzzle text, p_answer text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r escape_rooms; s escape_secrets; def jsonb; v_reward jsonb; p text;
begin
  if _esc_check_timeout(p_code) then return jsonb_build_object('ok', false, 'failed', true); end if;
  select * into r from escape_rooms where code = p_code for update;
  if not found or r.status <> 'playing' then raise exception '진행 중인 게임이 아니에요'; end if;
  if r.roles -> p_name is null then raise exception '이 방의 참가자가 아니에요'; end if;
  def := _esc_def(r.map);
  if def->'puzzles'->p_puzzle is null then raise exception '알 수 없는 퍼즐'; end if;
  if r.solved ? p_puzzle then return jsonb_build_object('ok', true, 'already', true); end if;
  for p in select jsonb_array_elements_text(def->'puzzles'->p_puzzle->'pre') loop
    if not (r.solved ? p) then raise exception '아직 잠겨 있어요'; end if;
  end loop;

  select * into s from escape_secrets where code = p_code;
  if _esc_norm(p_answer) <> _esc_norm(s.answers ->> p_puzzle) then
    return jsonb_build_object('ok', false);
  end if;

  v_reward := _esc_reward(r.map, p_puzzle, s.data) || jsonb_build_object('puzzle', p_puzzle, 'by', p_name);
  update escape_rooms
     set solved = solved || to_jsonb(p_puzzle), inventory = inventory || jsonb_build_array(v_reward)
   where code = p_code;
  return jsonb_build_object('ok', true, 'reward', v_reward);
end $$;

create or replace function escape_hint(p_code text, p_name text, p_puzzle text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r escape_rooms;
begin
  select * into r from escape_rooms where code = p_code for update;
  if not found or r.status <> 'playing' then raise exception '진행 중인 게임이 아니에요'; end if;
  if r.roles -> p_name is null then raise exception '이 방의 참가자가 아니에요'; end if;
  if r.hint_log ? p_puzzle then return jsonb_build_object('ok', true, 'hints_used', r.hints_used); end if;
  if r.hints_used >= 3 then return jsonb_build_object('ok', false, 'hints_used', r.hints_used); end if;
  update escape_rooms set hints_used = hints_used + 1, hint_log = hint_log || to_jsonb(p_puzzle) where code = p_code;
  return jsonb_build_object('ok', true, 'hints_used', r.hints_used + 1);
end $$;

-- 마지막 동시 태그: 3초 안에 서로 다른 두 사람이 누르면 탈출
create or replace function escape_tag(p_code text, p_name text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r escape_rooms; v_now double precision := extract(epoch from clock_timestamp());
  v_sync jsonb := '{}'::jsonb; k text; v double precision; v_secs int;
begin
  if _esc_check_timeout(p_code) then return jsonb_build_object('ok', false, 'failed', true); end if;
  select * into r from escape_rooms where code = p_code for update;
  if not found or r.status <> 'playing' then raise exception '진행 중인 게임이 아니에요'; end if;
  if r.roles -> p_name is null then raise exception '이 방의 참가자가 아니에요'; end if;
  if not (r.solved ? (_esc_def(r.map)->>'final')) then raise exception '아직 잠겨 있어요'; end if;

  for k, v in select key, value::double precision from jsonb_each_text(r.sync) loop
    if v_now - v <= 3 and k <> p_name then v_sync := v_sync || jsonb_build_object(k, v); end if;
  end loop;
  v_sync := v_sync || jsonb_build_object(p_name, v_now);

  if (select count(*) from jsonb_object_keys(v_sync)) >= 2 then
    v_secs := greatest(1, floor(extract(epoch from (now() - r.started_at)))::int);
    update escape_rooms
       set status = 'cleared', ended_at = now(), sync = v_sync, solved = solved || '"tag"'::jsonb
     where code = p_code;
    insert into escape_records (code, map, players, clear_secs, hints, total_secs)
    values (p_code, r.map, r.players, v_secs, r.hints_used, v_secs + r.hints_used * 120);
    return jsonb_build_object('ok', true, 'cleared', true, 'clear_secs', v_secs, 'total_secs', v_secs + r.hints_used * 120);
  end if;
  update escape_rooms set sync = v_sync where code = p_code;
  return jsonb_build_object('ok', true, 'cleared', false);
end $$;

create or replace function escape_timeout(p_code text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  return _esc_check_timeout(p_code);
end $$;

-- ---------- 권한 ----------
revoke all on escape_secrets from anon, authenticated;
revoke insert, update, delete on escape_rooms, escape_records from anon, authenticated;
grant select on escape_rooms, escape_records to anon, authenticated;

revoke execute on function _esc_generate(text), _esc_reward(text, text, jsonb), _esc_check_timeout(text),
  _esc_mech(text, jsonb) from public, anon, authenticated;
grant execute on function
  escape_create_room(text, text, text), escape_join(text, text, text), escape_leave(text, text),
  escape_set_map(text, text, text), escape_start(text, text), escape_get_clues(text, text),
  escape_submit(text, text, text, text), escape_hint(text, text, text), escape_tag(text, text), escape_timeout(text)
  to anon, authenticated;
