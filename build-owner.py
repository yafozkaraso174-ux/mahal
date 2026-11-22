from pathlib import Path
p=Path(__file__).parent/'admin.html'
s=p.read_text();start=s.index('/* @owner-dashboard */');end=s.index('\nif(token)boot();',start)
s=s[:start]+'/* @owner-dashboard */\n'+(p.parent/'admin-owner.src.js').read_text()+'\n'+(p.parent/'admin-invites.src.js').read_text()+s[end:]
p.write_text(s)
