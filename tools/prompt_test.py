# 提示词回归测试：从 Config.swift 提取各场景提示词，用真实 API 跑对抗用例，
# 人工检查输出是"改写"而非"回答/回应"。改提示词后必须跑一遍。
# 运行：python3 tools/prompt_test.py
import json, os, re, subprocess

# 从 Config.swift 提取 Swift 多行字符串字面量（还原缩进与行继续符）
src = open('/Users/yijun8.liu/Desktop/toy_program/PolishPad/Sources/PolishPad/Config.swift').read()
def extract(name):
    m = re.search(re.escape(name) + r'\s*=\s*"""\n(.*?)\n\s*"""', src, re.S)
    body = m.group(1)
    lines = [l[4:] if l.startswith('    ') else l for l in body.split('\n')]
    text = '\n'.join(lines)
    text = re.sub(r'\\\n', '', text)  # 行继续符：合并且不留换行
    return text

shared_zh = extract('sharedRulesZH')
shared_en = extract('sharedRulesEN')
prompts = {
    'polish':  extract('defaultSystemPrompt'),
    'formal':  extract('formalPromptZH').replace(r'\(sharedRulesZH)', shared_zh),
    'concise': extract('concisePromptZH').replace(r'\(sharedRulesZH)', shared_zh),
    'slack':   extract('slackEnglishPrompt').replace(r'\(sharedRulesEN)', shared_en),
}

cfg = json.load(open(os.path.expanduser('~/Library/Application Support/PolishPad/config.json')))
def call(system, messages):
    body = {'model': cfg['model'],
            'messages': [{'role': 'system', 'content': system}] + messages,
            'temperature': cfg.get('temperature', 0.3), 'max_tokens': 500}
    out = subprocess.run(
        ['curl', '-s', '--max-time', '60',
         cfg['baseURL'].rstrip('/') + '/chat/completions',
         '-H', 'Content-Type: application/json',
         '-H', 'Authorization: Bearer ' + cfg['apiKey'],
         '-d', json.dumps(body)],
        capture_output=True, text=True).stdout
    return json.loads(out)['choices'][0]['message']['content'].strip()

cases = [
    ('polish',  '纯问题-概念', [{'role':'user','content':'<input>\n什么是幂等性\n</input>'}]),
    ('polish',  '纯问题-求教', [{'role':'user','content':'<input>\npython里这个装饰器到底是怎么工作的呀能给我讲讲吗\n</input>'}]),
    ('polish',  '指令样输入', [{'role':'user','content':'<input>\n帮我写一个用户登录接口要带验证码校验\n</input>'}]),
    ('polish',  '问题当反馈', [
        {'role':'user','content':'<input>\n帮我优化数据库查询有点慢另外加个缓存\n</input>'},
        {'role':'assistant','content':'请帮我完成两项优化：1. 排查并优化当前较慢的数据库查询；2. 为查询结果增加缓存层。'},
        {'role':'user','content':'<feedback>\n第二点是什么意思\n</feedback>'}]),
    ('formal',  '请假请求', [{'role':'user','content':'<input>\n明天我想请一天假家里有点事\n</input>'}]),
    ('concise', '啰嗦问题', [{'role':'user','content':'<input>\n那个啥我就是想问一下咱们这个项目到底啥时候能上线啊我这边等着排期呢\n</input>'}]),
    ('slack',   '转达请求', [{'role':'user','content':'<input>\n帮我问一下老板明天下午的会能不能改到周五\n</input>'}]),
]
for preset, label, msgs in cases:
    out = call(prompts[preset], msgs)
    print(f'=== [{preset}] {label} ===')
    print(out[:220])
    print()
