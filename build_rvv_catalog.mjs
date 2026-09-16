import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Workbook, SpreadsheetFile } from '@oai/artifact-tool';

const spec = 'https://docs.riscv.org/reference/isa/unpriv/v-st-ext';
const encSource = 'https://github.com/riscv/riscv-opcodes/blob/master/extensions/rv_v';
const raw = await fs.readFile(path.join(os.tmpdir(), 'rv_v_opcodes.txt'), 'utf8');
const outDir = path.join('C:', 'Users', '강지민', 'Desktop', 'Vector_Core', 'outputs', 'rvv_instruction_20260916');
const outFile = path.join(outDir, 'RVV_Instruction_Decode_RV32.xlsx');

const bin = (x, n) => Number(x).toString(2).padStart(n, '0');
const parseVal = s => Number(s);
function parseLine(line) {
  const [mnemonic, ...tokens] = line.trim().split(/\s+/);
  const fields = {};
  for (const t of tokens) {
    const m = t.match(/^([^=]+)=(.+)$/);
    if (m) fields[m[1]] = parseVal(m[2]);
    else fields[t] = '*';
  }
  return { mnemonic, fields, tokens };
}
const entries = raw.split(/\r?\n/).filter(x => /^[a-z]/.test(x)).map(parseLine);

const permPrefixes = ['vrgather','vrgatherei16','vslide','vfslide','vcompress','vmerge','vfmerge','vmv','vfmv','viota','vid','vmsbf','vmsof','vmsif'];
function isPermutation(m) { return permPrefixes.some(x => m.startsWith(x)); }
function isFP(m) { return /^vf|^vmf/.test(m); }

function semantic(m) {
  const p = m.split('.')[0], suffix = m.slice(p.length);
  const f = isFP(m), unit = f ? 'FP32/FP64' : '정수';
  if (m.startsWith('vset')) return ['벡터 설정', 'AVL로 vl을 정하고 SEW·LMUL·tail/mask 정책을 vtype에 설정', '설정/CSR', 'vl·vtype 갱신. vill 및 지원하지 않는 조합 처리'];
  if (/^vrgatherei16/.test(m)) return ['Gather', 'vd[i] = vs2[vs1[i]]; 범위 밖 인덱스는 0', '교차 lane 라우터', '인덱스 EEW=16'];
  if (/^vrgather/.test(m)) return ['Gather', 'vd[i] = vs2[index[i]]; 범위 밖 인덱스는 0', '교차 lane 라우터', '인덱스는 vv/vx/vi 형식'];
  if (/^vslide1up|^vfslide1up/.test(m)) return ['Slide', 'vd[0]=스칼라, vd[i>0]=vs2[i-1]', 'lane 이동망', '상향 이동과 스칼라 삽입'];
  if (/^vslide1down|^vfslide1down/.test(m)) return ['Slide', 'vd[i<vl-1]=vs2[i+1], 마지막 요소=스칼라', 'lane 이동망', '하향 이동과 스칼라 삽입'];
  if (/^vslideup/.test(m)) return ['Slide', 'vd[i≥offset]=vs2[i-offset]; 아래쪽 요소는 기존 vd 유지', 'lane 이동망', 'vslideup은 아래쪽 body 요소를 보존'];
  if (/^vslidedown/.test(m)) return ['Slide', 'vd[i]=vs2[i+offset]; 소스 범위 밖은 0', 'lane 이동망', 'offset은 바이트가 아닌 요소 수'];
  if (p==='vcompress') return ['압축', 'vs1의 마스크 비트가 1인 vs2 요소만 앞쪽에 순서대로 채움', 'prefix-count + scatter', 'vs1 마스크 사용; 일반 vm 마스킹 불가'];
  if (p==='viota') return ['마스크 인덱스', 'vd[i] = i 이전의 활성 마스크 1 비트 누적 개수', 'prefix-sum', '스캔 동작'];
  if (p==='vid') return ['마스크 인덱스', 'vd[i] = 요소 인덱스 i', 'lane 인덱스 생성', '마스크된 요소는 정책 적용'];
  if (['vmsbf','vmsof','vmsif'].includes(p)) return ['마스크 인덱스', {vmsbf:'첫 1 이전 비트만 1',vmsof:'첫 1 위치만 1',vmsif:'첫 1 위치까지 1'}[p], '마스크 스캔', '입력 마스크의 첫 set bit 탐색'];
  if (p==='vmerge'||p==='vfmerge') return ['선택/Merge', 'v0[i]=0이면 vs2[i], 1이면 두 번째 피연산자', 'lane MUX', 'vm=0은 실행 마스크가 아닌 선택 비트'];
  if (/^vmv[1248]r$/.test(p)) return ['전체 레지스터 이동', '명시된 수의 전체 벡터 레지스터를 비트 그대로 복사', '레지스터 파일 복사', 'vl·vtype·마스크와 독립'];
  if (p==='vmv'||p==='vfmv') {
    if (/\.x\.s|\.f\.s/.test(m)) return ['스칼라 추출', 'vs2의 요소 0을 x/f 스칼라 레지스터로 복사', '스칼라 추출 경로', 'RV32에서 SEW>XLEN이면 저위 XLEN 비트'];
    if (/\.s\.x|\.s\.f/.test(m)) return ['요소 0 삽입', '스칼라 값을 vd 요소 0에 기록', '스칼라 삽입 경로', '나머지 요소는 유지'];
    return ['복사/Broadcast', /\.v\.v/.test(m)?'vs1의 활성 요소를 vd로 복사':'스칼라/즉시값을 활성 요소 전체로 복제', 'lane broadcast/MUX', '레지스터 그룹 중첩 규칙 확인'];
  }
  if (/^vfred|^vfwred|^vred|^vwred/.test(p)) {
    let op = p.includes('sum')?'합':p.includes('and')?'AND':p.includes('xor')?'XOR':p.includes('or')?'OR':p.includes('min')?'최솟값':'최댓값';
    return ['Reduction', `vs1[0]을 초기값으로 vs2 활성 요소를 ${op} 연산해 vd[0]에 기록`, 'reduction tree/누산기', p.includes('wred')?'결과 폭 2×SEW':(p==='vfredosum'?'순서 지정 FP 합':'활성 요소와 마스크만 계산')];
  }
  if (p==='vcpop') return ['마스크 Reduction', '활성 마스크의 1 비트 개수를 x 레지스터에 기록', 'popcount', '스칼라 결과'];
  if (p==='vfirst') return ['마스크 Reduction', '활성 마스크에서 첫 1의 인덱스 기록, 없으면 -1', 'priority encoder', '스칼라 결과'];
  if (/^vm(and|or|xor|nand|nor|xnor)/.test(p)) return ['마스크 논리', `두 마스크를 ${p.slice(2).toUpperCase()} 연산`, '마스크 비트 ALU', '각 요소는 1비트'];
  if (/^vmf?(seq|sne|slt|sle|sgt|eq|ne|lt|le|gt|ge)/.test(p)) {
    const op = p.match(/(seq|sne|slt|sle|sgt|eq|ne|lt|le|gt|ge)/)?.[0] || '';
    const symbols = {seq:'==',sne:'!=',slt:'<',sle:'<=',sgt:'>',eq:'==',ne:'!=',lt:'<',le:'<=',gt:'>',ge:'>='};
    return ['비교/마스크 생성', `vs2[i] ${symbols[op]} B이면 vd 마스크 비트=1, 아니면 0`, f?'FP 비교기':'정수 비교기', /u\./.test(m)?'unsigned 비교':(f?'FP NaN/예외 규칙 적용':'signed 비교 또는 동등 비교')];
  }
  if (/^vadc|^vsbc/.test(p)) return ['Carry 산술', p==='vadc'?'vd = vs2 + B + v0 carry-in':'vd = vs2 - B - v0 borrow-in', 'carry-chain ALU', 'v0는 carry/borrow 입력; 일반 마스크 아님'];
  if (/^vmadc|^vmsbc/.test(p)) return ['Carry 산술', p==='vmadc'?'각 요소의 덧셈 carry-out을 마스크로 기록':'각 요소의 뺄셈 borrow-out을 마스크로 기록', 'carry-chain ALU', m.endsWith('m')?'v0 carry/borrow-in 사용':'carry/borrow-in 0'];
  if (/^vfcvt|^vfwcvt|^vfncvt/.test(p)) {
    const direction = /\.xu?\.f\./.test(m)?'FP → 정수':/\.f\.xu?\./.test(m)?'정수 → FP':'FP → FP';
    return ['형변환', `${direction}; ${p.startsWith('vfw')?'결과 폭 2배':p.startsWith('vfn')?'결과 폭 1/2':'동일 폭'}${m.includes('.rtz.')?', 0 방향 절단':m.includes('.rod.')?', round-to-odd':''}`, 'FP 변환기', 'frm/fflags, 예외·NaN·포화 결과 규칙 적용'];
  }
  if (/^vzext|^vsext/.test(p)) return ['확장', `소스 폭을 ${m.match(/vf(\d)/)?.[1] || '?'}배로 ${p==='vzext'?'0':'부호'} 확장`, 'extend/pack', '원본 EEW와 결과 SEW 지원 여부 확인'];
  if (/^vfn?m(add|sub|acc|sac)|^vfm(add|sub|acc|sac)|^vfw(macc|nmacc|msac|nmsac)|^vwmacc|^vmadd|^vmacc|^vnmsub|^vnmsac/.test(p)) {
    const eq = {
      vmadd:'B × old(vd) + vs2', vnmsub:'vs2 − B × old(vd)', vmacc:'vs2 × B + old(vd)', vnmsac:'old(vd) − vs2 × B',
      vfmadd:'B × old(vd) + vs2', vfnmadd:'−(B × old(vd)) − vs2', vfmsub:'B × old(vd) − vs2', vfnmsub:'−(B × old(vd)) + vs2',
      vfmacc:'vs2 × B + old(vd)', vfnmacc:'−(vs2 × B) − old(vd)', vfmsac:'vs2 × B − old(vd)', vfnmsac:'−(vs2 × B) + old(vd)',
      vwmacc:'vs2 × B + old(vd)', vwmaccu:'vs2 × B + old(vd)', vwmaccsu:'vs2 × B + old(vd)', vwmaccus:'vs2 × B + old(vd)',
      vfwmacc:'vs2 × B + old(vd)', vfwnmacc:'−(vs2 × B) − old(vd)', vfwmsac:'vs2 × B − old(vd)', vfwnmsac:'−(vs2 × B) + old(vd)'
    }[p] || '곱셈 후 vd 누산/감산';
    return ['곱셈 누산', `vd[i] = ${eq}${f?' (융합 반올림)':''}`, f?'FP FMA':'정수 곱셈/누산기', p.includes('w')?'결과 폭 2×SEW; signed/unsigned 조합은 접미사 참조':'vd는 입력이기도 함'];
  }
  if (/^vfrsqrt7|^vfrec7/.test(p)) return ['FP 근사', p==='vfrec7'?'역수의 7비트 근사값 생성':'역제곱근의 7비트 근사값 생성', 'FP 근사 LUT/정규화', '정확한 div/sqrt 결과가 아님'];
  if (p==='vfsqrt') return ['FP 제곱근', 'vd[i] = sqrt(vs2[i])', 'FP sqrt', 'frm/fflags 적용'];
  if (p==='vfclass') return ['FP 분류', 'FP 요소의 NaN/무한대/0/정규·비정규 분류 비트 생성', 'FP class', '결과는 정수 비트 마스크'];
  if (/^vfsgnj/.test(p)) return ['FP 부호', `${p==='vfsgnj'?'B의 부호':p==='vfsgnjn'?'B 부호 반전':'vs2와 B의 부호 XOR'}을 vs2 크기 비트와 결합`, '부호비트 MUX/XOR', '산술 연산 없음'];
  if (/^vnclip/.test(p)) return ['고정소수점 Clip', '넓은 소스를 우시프트·반올림 후 좁은 폭으로 포화', 'shift/round/saturate', 'vxrm 사용, 포화 시 vxsat 설정'];
  if (/^vnsrl|^vnsra/.test(p)) return ['Narrow shift', `2×SEW 소스를 ${p==='vnsra'?'산술':'논리'} 우시프트 후 SEW로 축소`, 'barrel shifter', '하위 SEW 비트 기록'];
  if (/^vssrl|^vssra/.test(p)) return ['고정소수점 Shift', `${p==='vssra'?'산술':'논리'} 우시프트 후 vxrm 방식으로 반올림`, 'barrel shifter/round', 'vxrm 사용'];
  if (/^vsadd|^vssub/.test(p)) return ['포화 산술', `${p.includes('sub')?'뺄셈':'덧셈'} 결과를 ${p.endsWith('u')?'unsigned':'signed'} 범위로 포화`, 'add/sub + saturation', '포화 시 vxsat 설정'];
  if (p==='vsmul') return ['고정소수점 곱셈', 'signed fractional multiply 후 반올림·포화', 'fixed-point multiplier', 'vxrm 사용, 포화 시 vxsat 설정'];
  if (/^vaadd|^vasub/.test(p)) return ['평균 산술', `${p.includes('sub')?'vs2−B':'vs2+B'}의 평균을 vxrm으로 반올림`, 'add/sub + round', p.endsWith('u')?'unsigned':'signed'];
  if (/^vwmul|^vmul/.test(p)) return ['정수 곱셈', p.startsWith('vwm')?'SEW×SEW 곱의 2×SEW 결과':p.includes('h')?'곱의 상위 SEW 비트':'곱의 하위 SEW 비트', '정수 곱셈기', p.includes('su')?'signed × unsigned':p.endsWith('u')?'unsigned':'signed/하위 비트'];
  if (/^vdiv|^vrem/.test(p)) return ['정수 나눗셈', p.startsWith('vdiv')?'vs2 / B의 몫':'vs2 % B의 나머지', '정수 나눗셈기', p.endsWith('u')?'unsigned':'signed; 0 나눗셈/overflow 규칙'];
  if (/^vfwadd|^vfwsub|^vfwmul/.test(p)) return ['FP Widening', `FP ${p.includes('sub')?'뺄셈':p.includes('mul')?'곱셈':'덧셈'} 후 2×SEW 결과`, 'FP64 datapath', '표준 V에서는 FP32→FP64'];
  if (/^vfadd|^vfsub|^vfmul|^vfdiv|^vfrdiv|^vfrsub/.test(p)) {
    const op = p.includes('add')?'+':p.includes('sub')?'-':p.includes('mul')?'×':'÷';
    return ['FP 산술', `vd[i] = ${p.startsWith('vfr')?'B '+op+' vs2[i]':'vs2[i] '+op+' B'}`, 'FP 산술기', 'frm/fflags, NaN·예외 처리'];
  }
  if (/^vfmin|^vfmax/.test(p)) return ['FP Min/Max', `vs2와 B 중 ${p.includes('min')?'작은':'큰'} FP 값 선택`, 'FP 비교/MUX', 'NaN·±0 규칙 적용'];
  if (/^vwad|^vwsub/.test(p)) return ['정수 Widening', `${p.includes('sub')?'뺄셈':'덧셈'} 후 2×SEW 결과`, '넓은 add/sub', suffix.startsWith('.w')?'vs2는 이미 2×SEW':'입력 SEW, 결과 2×SEW'];
  if (/^vadd|^vsub|^vrsub/.test(p)) return ['정수 Add/Sub', `vd[i] = ${p==='vrsub'?'B − vs2[i]':p==='vsub'?'vs2[i] − B':'vs2[i] + B'}`, '정수 add/sub', 'overflow는 modulo 2^SEW'];
  if (/^vmin|^vmax/.test(p)) return ['정수 Min/Max', `vs2와 B의 ${p.startsWith('vmin')?'최솟값':'최댓값'} 선택`, '비교/MUX', p.endsWith('u')?'unsigned':'signed'];
  if (/^vand|^vor|^vxor/.test(p)) return ['비트 논리', `vs2 ${p.slice(1).toUpperCase()} B`, 'bitwise ALU', '요소별 독립'];
  if (/^vsll|^vsrl|^vsra/.test(p)) return ['Shift', `${p==='vsll'?'논리 좌':p==='vsrl'?'논리 우':'산술 우'}시프트`, 'barrel shifter', 'shift amount는 SEW에 맞게 마스킹'];
  return [f?'FP 기타':'정수 기타', `${p} 규격 동작`, f?'FP 연산기':'정수 ALU', '명세 세부 조건 참조'];
}

function profile(m, area, eew) {
  if ((area==='Load'||area==='Store') && /(?:oxei|uxei|oxseg|uxseg)/.test(m) && eew===64) return ['RV32 V 제외','Zve32f 제외','RV32의 index EEW=64는 V 범위 밖'];
  let z = '지원';
  if ((area==='Load'||area==='Store') && eew===64) z='Zve32f 제외';
  if (/^vfw|^vfncvt/.test(m)) z='Zve32f 제외';
  if (/^vwm|^vwad|^vwsub|^vnclip|^vnsr|^vwred/.test(m)) z='조건부(SEW≤16)';
  if (/^vzext\.vf8|^vsext\.vf8/.test(m)) z='Zve32f 제외';
  if (/^vzext\.vf4|^vsext\.vf4/.test(m)) z='조건부(SEW=32)';
  if (/^vfcvt/.test(m)) z='FP32에서 지원';
  if (/^vf/.test(m) && !/^vfw|^vfncvt/.test(m)) z='FP32에서 지원';
  return ['지원',z,''];
}

function memoryInfo(m, f) {
  const load = f['6..0']===0x07, area=load?'Load':'Store';
  let eew = Number(m.match(/(?:e|ei|re)(8|16|32|64)/)?.[1]);
  if (m==='vlm.v'||m==='vsm.v'||/^vs[1248]r/.test(m)) eew=8;
  let kind, meaning, block, constraint='';
  const seg = m.match(/seg([2-8])/), n=seg?Number(seg[1]):1;
  if (m==='vlm.v'||m==='vsm.v') {kind='마스크 메모리';meaning=load?'v0 형식의 마스크 비트를 메모리에서 읽음':'마스크 비트를 메모리에 저장';block='마스크 pack/unpack + LSU';constraint='EEW=8, vl 비트 수에 맞는 바이트 접근';}
  else if (/^vl[1248]re|^vs[1248]r/.test(m)) {kind='전체 레지스터';meaning=load?`${m.match(/^vl(\d)/)[1]}개 전체 레지스터를 로드`:`${m.match(/^vs(\d)/)[1]}개 전체 레지스터를 저장`;block='전체 레지스터 LSU';constraint='현재 vl·vtype과 독립; vm=1';}
  else if (/ff\./.test(m)) {kind='Fault-only-first';meaning=`${n}개 필드의 연속 접근; 첫 요소 이후 fault는 vl 단축 가능`;block='LSU + fault/vl 제어';constraint='첫 활성 요소 fault는 trap; 이후 fault는 vl 변경 가능';}
  else if (/^(vlux|vsux|vlox|vsox)/.test(m)) {kind=m.includes('ox')?'Indexed ordered':'Indexed unordered';meaning=`base + index[i](바이트 오프셋)로 ${n}개 필드 ${load?'로드':'저장'}`;block='indexed address generator + LSU';constraint='접미사 EEW는 index 폭; 데이터 폭은 SEW';}
  else if (/^(?:vlsseg|vssseg|vlse(?:8|16|32|64)|vsse(?:8|16|32|64))/.test(m)) {kind='Strided';meaning=`base + i×rs2(stride) 위치에서 ${n}개 필드 ${load?'로드':'저장'}`;block='stride address generator + LSU';constraint='rs2는 바이트 stride; 0/음수 가능';}
  else {kind=n>1?'Segment unit-stride':'Unit-stride';meaning=`연속 주소에서 ${n}개 필드 ${load?'로드':'저장'}`;block='unit-stride address generator + LSU';constraint=n>1?'nf=N−1; EMUL×N≤8':'EEW는 메모리 요소 폭';}
  if (n>1) constraint += '; 필드별 레지스터 그룹 정렬 확인';
  return {area,kind,meaning,block,constraint,eew,n};
}

function normalRow(e) {
  const {mnemonic:m,fields:f,tokens} = e;
  const opcode=f['6..0'];
  const area = opcode===0x07?'Load':opcode===0x27?'Store':m.startsWith('vset')?'Configuration':isPermutation(m)?'Permutation':'ALU';
  const mem = area==='Load'||area==='Store'?memoryInfo(m,f):null;
  const [sub,meaning,block,note]=mem?[mem.kind,mem.meaning,mem.block,mem.constraint]:semantic(m);
  const f3=f['14..12']===undefined?'—':`b${bin(f['14..12'],3)}`;
  const f6=f['31..26']===undefined?'—':`b${bin(f['31..26'],6)}`;
  const vm=f.vm==='*'?'가변':f['25']===1?'1 고정':f['25']===0?'0 고정':'—';
  let fmt='';
  if (m==='vsetvli') fmt='vsetvli rd, rs1, vtypei';
  else if (m==='vsetivli') fmt='vsetivli rd, uimm, vtypei';
  else if (m==='vsetvl') fmt='vsetvl rd, rs1, rs2';
  else if (mem) fmt=mem.kind==='마스크 메모리'||mem.kind==='전체 레지스터'?`${m} ${area==='Load'?'vd':'vs3'}, (rs1)`:`${m} ${area==='Load'?'vd':'vs3'}, (rs1)${mem.kind==='Strided'?', rs2':mem.kind.startsWith('Indexed')?', vs2':''}${vm==='가변'?', v0.t':''}`;
  else {
    const ops=[];
    if (f.rd==='*') ops.push(isFP(m)?'fd':'rd'); else if (f.vd==='*') ops.push('vd');
    const fma=/^(?:vmadd|vnmsub|vmacc|vnmsac|vwmacc|vf(?:madd|nmadd|msub|nmsub|macc|nmacc|msac|nmsac)|vfw(?:macc|nmacc|msac|nmsac))\./.test(m);
    if (fma) {
      if (f.vs1==='*') ops.push('vs1'); else if (f.rs1==='*') ops.push(isFP(m)?'fs1':'rs1');
      if (f.vs2==='*') ops.push('vs2');
    } else {
      if (f.vs2==='*') ops.push('vs2');
      if (f.vs1==='*') ops.push('vs1'); else if(f.rs1==='*')ops.push(isFP(m)?'fs1':'rs1'); else if(f.simm5==='*')ops.push('simm5');else if(f.zimm5==='*')ops.push('uimm5');
    }
    if (vm==='가변') ops.push('[v0.t]');
    fmt=`${m} ${ops.join(', ')}`;
  }
  const fixed=(mem&&f.nf==='*'?['31..29=0',...tokens.filter(t=>t.includes('='))]:tokens.filter(t=>t.includes('='))).join(' ');
  const [vStatus,zStatus,extra] = profile(m,area,mem?.eew);
  const addrMode=mem?`b${f['27..26']!==undefined?bin(f['27..26'],2):'00'}`:'—';
  const nf=mem?`b${f['31..29']!==undefined?bin(f['31..29'],3):'000'}`:'—';
  const lumop=mem?(f['24..20']!==undefined?`b${bin(f['24..20'],5)}`:'vs2/rs2'):'—';
  let width=mem?`${mem.eew||8} bit${mem.kind.startsWith('Indexed')?' index; data=SEW':''}`:isFP(m)?'FP32/FP64':'SEW';
  if (/^vfw|^vfncvt|^vwm|^vwad|^vwsub|^vnclip|^vnsr|^vwred/.test(m)) width='SEW ↔ 2×SEW';
  return [area,sub,m,fmt,`0x${opcode.toString(16).padStart(2,'0')} (${opcode===0x57?'OP-V':opcode===0x07?'LOAD-FP':'STORE-FP'})`,f3,f6,vm,addrMode,nf,lumop,width,meaning,block,vStatus,zStatus,[note,extra].filter(Boolean).join('; '),fixed];
}

const rows=entries.map(normalRow);
const baseMem = entries.filter(e => e.fields['6..0']===0x07||e.fields['6..0']===0x27);
for (const e of baseMem) {
  const m=e.mnemonic;
  if (/^vlm|^vsm|^vl[1248]re|^vs[1248]r/.test(m)) continue;
  const match=m.match(/^(vle|vse|vlse|vsse|vluxei|vsuxei|vloxei|vsoxei)(8|16|32|64)(ff)?\.v$/);
  if (!match) continue;
  const [,stem,w,ff]=match;
  for (let n=2;n<=8;n++) {
    const map={vle:'vlseg',vse:'vsseg',vlse:'vlsseg',vsse:'vssseg',vluxei:'vluxseg',vsuxei:'vsuxseg',vloxei:'vloxseg',vsoxei:'vsoxseg'};
    const segName=`${map[stem]}${n}${stem.includes('xei')?'ei':'e'}${w}${ff||''}.v`;
    const fields={...e.fields,'31..29':n-1}; delete fields.nf;
    const tokens=e.tokens.map(t=>t==='nf'?`31..29=${n-1}`:t);
    rows.push(normalRow({mnemonic:segName,fields,tokens}));
  }
}
rows.sort((a,b)=>['Configuration','ALU','Permutation','Load','Store'].indexOf(a[0])-['Configuration','ALU','Permutation','Load','Store'].indexOf(b[0]) || a[1].localeCompare(b[1]) || a[2].localeCompare(b[2]));

const wb=Workbook.create();
const overview=wb.worksheets.add('개요');
const catalog=wb.worksheets.add('명령어');
const decode=wb.worksheets.add('디코드 기준');
for (const s of [overview,catalog,decode]) s.showGridLines=false;
overview.tabColor='#183153'; catalog.tabColor='#37658C'; decode.tabColor='#6C8399';
const navy='#183153', mid='#315D80', pale='#E9F1F7', ink='#1D2B36', amber='#FFF2D8';
function baseStyle(sheet,range){sheet.getRange(range).format.font={name:'Arial',size:10,color:ink};sheet.getRange(range).format.verticalAlignment='center';}
function title(sheet,cell,text){sheet.getRange(cell).values=[[text]];sheet.getRange(cell).format.font={name:'Arial',size:15,bold:true,color:navy};}
function header(sheet,range){sheet.getRange(range).format={fill:navy,font:{name:'Arial',size:10,bold:true,color:'#FFFFFF'},verticalAlignment:'center',horizontalAlignment:'center',rowHeight:32,wrapText:true};}
title(overview,'A2','RV32 Vector 명령어 구현 범위');
overview.getRange('A3:F3').format.borders={bottom:{style:'thin',color:'#9CB4C9'}};
overview.getRange('A5:B5').values=[['기준 ISA','RV32IMFC + V를 목표로 하면 D가 필수이므로 RV32IMFDCV가 됨']];
overview.getRange('A6:B6').values=[['기본 코어 유지안','D 없이 RV32IMFC_Zve32f로 구현 가능. 이 경우 전체 V 명칭은 사용할 수 없음']];
overview.getRange('A7:B7').values=[['V 필수 파라미터','VLEN ≥ 128, EEW/SEW 8·16·32·64, FP32·FP64, precise trap']];
overview.getRange('A8:B8').values=[['Zve32f 범위','VLEN ≥ 32, EEW/SEW 8·16·32, FP32, 정수/고정소수점/마스크/순열/메모리']];
overview.getRange('A9:B9').values=[['RV32 예외','V에서도 인덱스 EEW=64인 indexed load/store는 지원 범위 밖']];
overview.getRange('A10:B10').values=[['표의 지원 열','V 지원은 RV32 전체 V 기준. Zve32f 지원은 D 없이 F만 있는 구성 기준']];
overview.getRange('A12:D12').values=[['영역','명령어 행 수','핵심 디코드','주요 하드웨어']];
header(overview,'A12:D12');
const areas=['Configuration','ALU','Permutation','Load','Store'];
const meta={Configuration:['OP-V / funct3=111','vl·vtype CSR'],ALU:['OP-V / funct3+funct6','정수/고정소수점/FP ALU'],Permutation:['OP-V / funct3+funct6','lane 이동·crossbar·mask scan'],Load:['LOAD-FP / mop+lumop+nf+width','주소 생성·LSU'],Store:['STORE-FP / mop+sumop+nf+width','주소 생성·LSU']};
overview.getRange('A13:D17').values=areas.map(a=>[a,rows.filter(r=>r[0]===a).length,...meta[a]]);
overview.getRange('A19:B19').values=[['구현 시 읽는 순서','① 디코드 기준 → ② 명령어 필터 → ③ 파라미터/블록 확정']];
overview.getRange('A21:B21').values=[['중요 제어','vl, vtype(SEW·LMUL·vta·vma), vstart, v0 마스크, vxrm/vxsat, frm/fflags']];
overview.getRange('A22:B22').values=[['정밀 예외','마스크·tail·vstart 상태, fault-only-first load, 메모리 접근 순서까지 ISA 동작에 포함']];
baseStyle(overview,'A5:D22');
header(overview,'A12:D12');
overview.getRange('A5:A10').format.font={name:'Arial',size:10,bold:true,color:mid};
overview.getRange('A19:A22').format.font={name:'Arial',size:10,bold:true,color:mid};
overview.getRange('A5:A22').format.columnWidth=20;
overview.getRange('B5:B22').format.columnWidth=78;
overview.getRange('C12:C17').format.columnWidth=30;
overview.getRange('D12:D17').format.columnWidth=30;
overview.getRange('A5:D10').format.rowHeight=26;
overview.getRange('A13:D17').format.rowHeight=25;
overview.getRange('B13:B17').format.numberFormat='#,##0';

title(catalog,'A2','RVV 1.0 명령어 디코드 및 동작');
catalog.getRange('A3').values=[['필터: 영역, funct3/funct6, 지원 프로파일, RTL 블록. B=두 번째 피연산자, old(vd)=덮어쓰기 전 대상 값.']];
catalog.getRange('A3').format.font={name:'Arial',size:10,italic:true,color:'#526674'};
const headers=['영역','세부 기능','Mnemonic','어셈블리 형식','opcode','funct3','funct6','vm','mop','nf','lumop/sumop·vs2','폭','실제 동작','RTL 블록','RV32 V','Zve32f','구현 제약/예외','고정 인코딩'];
catalog.getRange('A5:R5').values=[headers];
catalog.getRange(`A6:R${5+rows.length}`).values=rows;
baseStyle(catalog,`A6:R${5+rows.length}`);
header(catalog,'A5:R5');
catalog.getRange('A5:R5').format.rowHeight=38;
const widths=[16,21,23,39,10,10,10,10,9,9,19,21,54,28,16,20,55,67];
for(let i=0;i<widths.length;i++) catalog.getRangeByIndexes(4,i,rows.length+1,1).format.columnWidth=widths[i];
catalog.getRange(`A6:R${5+rows.length}`).format.rowHeight=22;
catalog.getRange(`E6:K${5+rows.length}`).format.horizontalAlignment='center';
catalog.getRange(`O6:P${5+rows.length}`).format.horizontalAlignment='center';
catalog.tables.add(`A5:R${5+rows.length}`,true,'RVVInstructions');
catalog.freezePanes.freezeRows(5);

title(decode,'A2','디코드 필드와 구현 규칙');
decode.getRange('A4:D4').values=[['필드','비트','값/범위','디코드 의미']]; header(decode,'A4:D4');
const fieldRows=[
 ['major opcode','[6:0]','0x57 / 0x07 / 0x27','OP-V / LOAD-FP / STORE-FP'],
 ['OP-V funct3','[14:12]','000 OPIVV · 001 OPFVV · 010 OPMVV · 011 OPIVI · 100 OPIVX · 101 OPFVF · 110 OPMVX · 111 OPCFG','두 번째 피연산자 종류와 연산 그룹'],
 ['OP-V funct6','[31:26]','6비트','같은 funct3 안에서 구체적인 연산 지정'],
 ['vm','[25]','0: v0.t 활성 조건 / 1: 마스크 없음','예외: merge·carry·compress 등은 선택/입력 의미가 다름'],
 ['vd/rd','[11:7]','5비트','벡터 또는 스칼라 목적지'],
 ['vs1/rs1/imm','[19:15]','5비트','funct3에 따라 벡터·정수·FP·즉시값'],
 ['vs2','[24:20]','5비트','벡터 소스. 메모리에서는 lumop/sumop 또는 stride/index'],
 ['memory width','[14:12]','000=8 · 101=16 · 110=32 · 111=64','메모리 EEW. indexed에서는 데이터가 아닌 인덱스 폭'],
 ['mop','[27:26]','00 unit · 01 indexed unordered · 10 stride · 11 indexed ordered','주소 생성 방식'],
 ['mew','[28]','0','1은 현재 RVV 1.0에서 예약'],
 ['nf','[31:29]','000~111','segment 필드 수 = nf+1. 일반 접근은 000'],
 ['lumop','[24:20]','00000 일반 · 01000 whole · 01011 mask · 10000 fault-only-first','mop=00 load의 하위 동작'],
 ['sumop','[24:20]','00000 일반 · 01000 whole · 01011 mask','mop=00 store의 하위 동작'],
 ['SEW/LMUL','vtype','SEW=8/16/32/64 · LMUL=1/8~8','요소 폭과 레지스터 그룹 크기. 지원하지 않는 조합은 vill'],
 ['EMUL','계산값','(EEW/SEW)×LMUL','메모리/폭변경 연산의 실제 레지스터 그룹 크기'],
 ['mask/tail','vtype','vma / vta','비활성·꼬리 요소의 유지/agnostic 정책'],
 ['vstart','CSR 0x008','요소 인덱스','정밀 예외 후 해당 요소부터 재시작'],
 ['vxrm/vxsat','CSR 0x00A / 0x009','고정소수점 반올림 / 포화 플래그','clip·saturating·rounding 산술에 필요'],
 ['frm/fflags','FP CSR','FP 반올림 / 예외 플래그','FP 연산 및 변환에 필요'],
];
decode.getRange(`A5:D${4+fieldRows.length}`).values=fieldRows;
baseStyle(decode,`A5:D${4+fieldRows.length}`);
decode.getRange(`A5:D${4+fieldRows.length}`).format.rowHeight=28;
decode.getRange('A:A').format.columnWidth=22; decode.getRange('B:B').format.columnWidth=15; decode.getRange('C:C').format.columnWidth=87; decode.getRange('D:D').format.columnWidth=61;
decode.getRange('A26:B26').values=[['소스','공식 문서/인코딩 정의']]; header(decode,'A26:B26');
decode.getRange('A27:B30').values=[
 ['RVV 1.0 명세',spec],['공식 opcode 정의',encSource],
 ['V 프로파일','https://github.com/riscv/riscv-vme/blob/main/src/unpriv/v-st-ext.adoc'],
 ['Zve32x/Zve32f','https://github.com/riscv/riscv-isa-manual/blob/main/src/unpriv/zve32f.adoc']
];
decode.getRange('B27:B30').format.font={name:'Arial',size:10,color:'#145A9C'};
decode.getRange('A32:D32').values=[['범위','기본 rv_v 인코딩 375개 + nf=1..7의 segment 확장형','별도 확장 Zvfh, Zvbb, Zvkn 등 제외','어셈블러 pseudo-instruction은 독립 opcode로 세지 않음']];
decode.getRange('A32:D32').format.fill=amber;
decode.getRange('A32:D32').format.rowHeight=28;
decode.getRange('A34:D34').values=[['예시 명령어','opcode / funct3','추가 식별 필드','동작 경로']]; header(decode,'A34:D34');
decode.getRange('A35:D39').values=[
 ['vadd.vv','0x57 / b000','funct6=b000000','vs2와 vs1을 요소별 덧셈 → 정수 ALU'],
 ['vfmadd.vv','0x57 / b001','funct6=b101000','vs1×old(vd)+vs2 → FP FMA'],
 ['vrgather.vv','0x57 / b000','funct6=b001100','vs1 인덱스로 vs2 요소 선택 → crossbar'],
 ['vle32.v','0x07 / b110','mop=b00, nf=b000, lumop=b00000','연속 주소 32비트 load → LSU'],
 ['vsuxei32.v','0x27 / b110','mop=b01, nf=b000, index EEW=32','순서 비보장 indexed store → 주소 생성기+LSU']
];
baseStyle(decode,'A35:D39'); decode.getRange('A35:D39').format.rowHeight=28;

wb.recalculate();
const check=await wb.inspect({kind:'table',range:'개요!A12:D17',include:'values',tableMaxRows:8,tableMaxCols:4,maxChars:2500});
console.log(check.ndjson);
const error=await wb.inspect({kind:'match',searchTerm:'#REF!|#DIV/0!|#VALUE!|#NAME\\?|#N/A|#NUM!',options:{useRegex:true,maxResults:20},summary:'final errors',maxChars:1000});
console.log(error.ndjson);
await fs.mkdir(outDir,{recursive:true});
for(const [sheetName,range,file] of [['개요','A1:D23','overview.png'],['명령어','A1:H17','catalog.png'],['디코드 기준','A1:D13','decode.png']]) {
  const png=await wb.render({sheetName,range,scale:1.4,format:'png'});
  await fs.writeFile(path.join(outDir,file),new Uint8Array(await png.arrayBuffer()));
}
const output=await SpreadsheetFile.exportXlsx(wb);
await output.save(outFile);
console.log(JSON.stringify({outFile,count:rows.length,areas:Object.fromEntries(areas.map(a=>[a,rows.filter(r=>r[0]===a).length]))}));
