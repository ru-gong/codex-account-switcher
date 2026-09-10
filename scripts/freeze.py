#!/usr/bin/env python3
import pathlib, hashlib, json, argparse
p=argparse.ArgumentParser(); p.add_argument('--output',required=True); args=p.parse_args()
root=pathlib.Path(__file__).resolve().parent.parent
files={}
for path in sorted(root.rglob('*')):
    rel=path.relative_to(root)
    if path.is_file() and path.suffix not in ['.profraw','.profdata'] and not any(part in ['.build','dist','.git','evidence','__pycache__'] for part in rel.parts):
        files[str(rel)]=hashlib.sha256(path.read_bytes()).hexdigest()
frozen=hashlib.sha256(''.join(f'{k}:{v}\n' for k,v in sorted(files.items())).encode()).hexdigest()
out=pathlib.Path(args.output); out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps({'source_id':frozen,'algorithm':'SHA256(sorted relative-path:sha256 newline)','files':files},ensure_ascii=False,indent=2)+'\n')
print('Source ID:',frozen)
