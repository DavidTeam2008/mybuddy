# MyBuddy fixture semantic review — `fix-full-edge` (84 rows)

> **Status:** LLM screening from 2026-11-28, not human signoff. The run is
> `fix-full-edge`, recorded before the row-82 assembler fix. Row 82 is fixed in
> code and awaits a fresh device run; the remaining findings are pre-fix.
> Use this as a triage list, not as a release gate.

## Inputs and method
- Transcript: `.device-state/fixture-runs/fix-full-edge/transcript.tsv` (84 final rows, indexes 0–83).
- Ground truth: `tools/fixtures/ted-cue132-331.tsv` (194 cues, TED 08:31–21:36).
- Diagnostics: `.device-state/fixture-runs/fix-full-edge/duiyi-diagnostics.json` (metadata only by design; no ASR/translation body text is recorded). The 4096-event ring buffer had already evicted all events for rows 0–4.
- Mechanical score from `score.json`: 84 app rows, sourceCoverage 0.988, WER 0.0264, 19 deletions / 21 substitutions / 2 insertions vs ground truth, 0 empty translations.
- Cross-checked against the earlier `fix-full-final` and `fix-full-1` runs where useful.
- Severity: **critical** = meaning reversed, fabricated content, wrong number/name/negation, or whole clause omitted; **major** = significant omission/mistranslation changing listener understanding; **minor** = awkward wording, terminology, particles, punctuation, style; **SD-A** = source defect, ASR; **SD-X** = source defect, assembler.

## Row-by-row findings

| Row | Source excerpt | Translation excerpt | Severity | Finding |
|---:|---|---|---|---|
| 0 | "Highlight an Asian woman's Asian identity before a math test? ... diagnostic of sports intelligence." | "在数学考试前突出一个亚洲女性的亚洲身份？ ... 是对运动智力的诊断。" | **SD-A critical** + minor | Ground truth cue 142 "white men perform better." is absent at the row 0/1 boundary; row 1 begins with dangling "perform better." The white-men/black-men contrast is destroyed. Minor: "运动智力" for "sports intelligence". |
| 1 | "perform better. Lead them to believe ... black men do. ... painter's coat." | "表现更好。 引导他们相信 ... 黑人男性确实如此。 ... 油漆工的外套更好。" | **major (inherited SD)** + minor | Translation begins with subjectless "表现更好。" because "white men" is missing; the listener cannot tell who performs better. Minor: "实验室外套" is a literal "lab coat". |
| 2 | "In all of these cases ... different beliefs. And in each case, it was their belief ..." | "在所有这些情况下 ... 不同的信仰。 ... 都是他们的信念 ..." | minor | "beliefs" is "信仰" (faith/creed) in sentence 1 and "信念" in sentence 2; wrong sense and inconsistent terminology. |
| 3 | "How you see yourself and your circumstances ..." | "你如何看待自己和你的环境 ..." | minor | "circumstances" rendered "环境" (environment), not "处境/境况". Meaning otherwise preserved. |
| 4 | "It's almost as if our beliefs place a virtual reality headset on us." | "几乎就像我们的信仰给我们戴上了虚拟现实耳机。" | minor | "信仰" again for beliefs; "虚拟现实耳机" is acceptable but "VR 头显" is the natural term. |
| 5 | "A headset that allows us to see things that aren't really there ..." | "耳机让我们看到不存在的东西 ..." | OK | Faithful. |
| 6 | "We have these headsets even when they're miles from the truth." | "即使它们与真相相去甚远，我们也有这些耳机。" | OK | Faithful. |
| 7 | "the top model, Cameron Rushell ... are some of the most physically insecure people ..." | "顶级模特Cameron Rushell ... 是地球上身体最没有安全感的人。" | minor + SD-A minor | Name "Russell" misheard as "Rushell"; "some of the most" strengthened to "最...的人". |
| 8 | "an award-winning author, Lydia Yuknovic. share ... literary representation ..." | "获奖作家Lydia Yuknovic分享了 ... 文学代表。" | **major** + SD-A minor | "literary representation" mistranslated as "文学代表" (should be 文学经纪代理/出版代理); listener cannot understand the agent offer. SD-A: "Lidia Yuknavitch shared" → "Lydia Yuknovic share"; "the" dropped. Minor: "没有跟进" literal. |
| 9 | "We don't always know how to hope or say yes or choose the big thing ..." | "我们并不总是知道如何希望或说是或选择大事 ..." | minor | Literal "如何希望", "说是", "选择大事"; meaning survives but reads unnaturally. |
| 10 | "It's the shame we carry. The shame of not believing we deserve it." | "这是我们承受的耻辱。 不相信我们活该的耻辱。" | minor | "shame" → "耻辱" (disgrace) rather than 羞耻; "deserve it" → "活该" carries a punitive connotation. Negation preserved. |
| 11 | "Our headsets have us living into a false reality." | "我们的耳机让我们生活在一个虚假的现实中。" | OK | Faithful. |
| 12 | "They also cause us to bump into each other." | "他们还导致我们互相碰撞。" | OK | Faithful. |
| 13 | "Once I've been dating someone for a few weeks ... Then he went on a work trip for four days. silence." | "一旦我和某人约会了几周 ... 然后他出差了四天。沉默。" | minor + SD-A minor | "Once" rendered as conditional "一旦" (source defect: ASR dropped comma/"I'd"); "for four days" attached to the trip rather than to the silence; "沉默。" is a bare fragment. |
| 14 | "I didn't hear a word. How would you interpret this? ..." | "我一个字都没听到。 你会如何解释这个？ ..." | OK | Faithful. |
| 15 | "My beliefs led me to wonder what I had done or said ..." | "我的信念让我想知道我做了什么或说了什么 ..." | OK | Faithful. |
| 16 | "I shared his silence with friends. One, who admits she has trouble trusting people ..." | "我和朋友们分享了他的沉默。 一个人承认她很难相信别人 ..." | minor | "One" → "一个人" (a person) instead of "其中一位"; "分享了他的沉默" literal but understandable. |
| 17 | "Another, who admits he's afraid of rejection ... an upcoming wedding." | "另一个人承认他害怕被拒绝 ... 因为我没有邀请他作为我即将到来的婚礼的约会对象。" | **major** + SD-A major | "an upcoming wedding" becomes "我即将到来的婚礼" — adds "my", falsely implying the narrator is getting married. SD-A: ground truth "she's afraid" misheard as "he's"; translation follows "他". Minor: "约会对象" for "date". |
| 18 | "who has trouble with commitment ... was taking some space." | "在承诺方面有问题 ... 占用了一些空间。" | minor | "taking some space" → "占用了一些空间" (occupying space) instead of "需要一些空间"; the emotional reason is obscured. |
| 19 | "Each person saw the same situation through the lens of their own headset." | "每个人都通过自己的耳机镜头看到了相同的情况。" | OK | Faithful; "耳机镜头" is a mixed metaphor but understandable. |
| 20 | "Who was right?" | "谁是对的？" | OK | Faithful. |
| 21 | "Moving too fast, I should pull back. But if you's feeling rejected, this will just hurt him more." | "走得太快了，我应该后退。 但如果你感到被拒绝，这只会更伤害他。" | **major** + SD-A major | ASR "he's" → "you's"; translation uses "你" and then "他" in the same sentence, producing an incoherent addressee shift. SD-A also "would" → "will". |
| 22 | "Feeling rejected, I should up my calls and invite them to the wedding ... push him away further." | "感到被拒绝，我应该打电话邀请他们参加婚礼 ... 这只会把他推得更远。" | **major** + SD-A major | ASR "him" → "them"; translation says "邀请他们" then "他", mixing a group and Ben. Minor: "up my calls" loses "increase" (just "打电话"). |
| 23 | "As I was ping ponging around in my own headset ..." | "当我戴着自己的耳机到处打乒乓球时 ..." | **major** + SD-A minor | "ping-ponging" (bouncing between thoughts) literalized as playing table tennis; the mental-image is wrong. Minor: "你准备好迎接Ben的耳机里发生了什么了吗？" is ungrammatical. SD-A: "friends'" → "friends's". |
| 24 | "He'd been deeply hurt by a pastor relationship ... when his insecurities got the best of him." | "他被牧师的关系深深伤害了 ... 当他的不安全感对他来说是最好的时，他退出了。" | **major** + SD-A major | "got the best of him" (overcame him) → "对他来说是最好的" (was best for him), reversing the clause. SD-A: "past relationship" misheard as "pastor relationship", fabricating a pastor. |
| 25 | "It was none of the things anyone had guessed." | "这不是任何人猜到的。" | minor | Ambiguous; "和任何人猜的都不一样" would preserve the sense more clearly. |
| 26 | "Sometimes our headsets get in the way of our relationships." | "有时我们的耳机会妨碍我们的关系。" | OK | Faithful. |
| 27 | "It took me a long time to learn this." | "我花了很长时间才学会这个。" | OK | Faithful. |
| 28 | "Just as our beliefs can hold us back, they can also propel us forward." | "就像我们的信仰可以阻止我们一样，它们也可以推动我们前进。" | minor | "信仰" again for beliefs; otherwise faithful. |
| 29 | "Let's go back to the scar study for a moment." | "让我们回到疤痕研究一会儿。" | minor | "for a moment" → "一会儿" is slightly off; "片刻" is natural. |
| 30 | "Imagine the researchers place something on the participants's faces ..." | "想象一下，研究人员在参与者的脸上放置一些东西 ..." | OK | Faithful. SD-A minor: "participants'" → "participants's". |
| 31 | "Now what do you think they believe about others' responses?" | "现在，你认为他们对其他人的反应有什么看法？" | OK | Faithful. |
| 32 | "How do you think they show up differently?" | "你认为他们有什么不同？" | minor | Loses "show up" (how they present/behave); becomes a generic "how are they different". |
| 33 | "What difference does it make if you believe you're ugly or gorgeous? ... It seems a big one." | "... 这看起来是个大人物。" | **critical** | "It seems a big one" (a big difference) → "这看起来是个大人物" (a big person/VIP): fabricates a person; the intended meaning is lost. Minor: "华丽" for gorgeous. |
| 34 | "I finally learned this lesson. My headset led me to law school." | "我终于学到了这个教训。 我的耳机把我带到了法学院。" | OK | Faithful. |
| 35 | "There, my long held false beliefs were reinforced." | "在那里，我长期以来的错误信念得到了加强。" | OK | Faithful; "强化" would be more idiomatic. |
| 36 | "Aim for perfection, follow the crowd, fear failure." | "以完美为目标，跟随人群，害怕失败。" | OK | Faithful. |
| 37 | "This was a familiar path." | "这是一条熟悉的道路。" | OK | Faithful. |
| 38 | "I signed up for a class outside the law school. called Design thinkinging Boot Camp." | "就报名参加了法学院以外的一门课程，叫做设计思维训练营。" | OK | SD-A minor: "thinkinging" stutter normalized correctly. |
| 39 | "A class that promised to unleash my creative potential." | "一个承诺释放我创造力的班级。" | minor | "班级" for a course/class; "课程" is natural. |
| 40 | "or more accurately, pull on almost every single one of my ropes." | "或者更准确地说，几乎拉动我的每一根绳子。" | minor | Literal "拉动...绳子"; the rope metaphor survives but is awkward. |
| 41 | "there is by definition no one to look to you for the answers." | "根据定义，没有人可以向你寻找答案。" | **major** + SD-A major | ASR inserted "you"; translation says "no one can look to you for answers", losing the intended "no one to look to for the answers" (no authority to consult). Also ungrammatical: "向你寻找答案". |
| 42 | "I had to put myself out there because innovation doesn't come from playing it safe." | "我不得不把自己放在那里，因为创新不是来自安全游戏。" | **major** | Two idioms literalized: "put myself out there" → "把自己放在那里" and "playing it safe" → "安全游戏"; the risk-taking claim is obscured. |
| 43 | "The best Dess came only After multiple failed attempts ..." | "最好的Dess只有在多次尝试失败后才会出现 ..." | **major** + SD-A major | ASR "designs" → "Dess"; the translation leaves "Dess" untranslated, so the listener reads "the best Dess" with no meaning. Prior runs recognized "designs". |
| 44 | "because all of the things that would help me succeed, Same things I believed ..." | "因为所有能帮助我成功的事情，都是我这么多年来一直相信的 ..." | minor + SD-A minor | ASR dropped "were the", leaving a fragment; translation recovers the intended sense but is convoluted. "挣扎了" is awkward. |
| 45 | "to live as I had before my ropes." | "像我绳索前一样生活。" | minor | Awkward; "像我戴上绳索之前那样生活" is clear. |
| 46 | "I felt free in a way I hadn't since I was six years old." | "我从六岁起就从未有过这种自由的感觉。" | OK | Faithful. |
| 47 | "And I accomplished things I never would have imagined possible." | "我完成了我从未想象过的事情。" | OK | Faithful. |
| 48 | "I was astounded, proud, liberated, and confused." | "我感到很驚訝，很自豪，很解放了，" | **major** | "and confused" (困惑) is omitted; translation ends mid-list with a comma. Diagnostics: final translation job (srcLen 48, seq 974) failed twice with `corruptedOutput`; the stored text is a stale non-final partial translation. Reproduces in the two earlier runs. Minor: traditional 驚訝; "很解放了" ungrammatical. |
| 49 | "the beliefs that held me back in this class. of the same ones ..." | "我想知道阻碍我在这门课上的信念。是否是那些阻碍我生活其他部分的信念。" | minor + SD-A minor | ASR "were" → "of" and a sentence boundary; translation recovers "是否是". "生活其他部分" → "生活其他方面" is more natural. |
| 50 | "The seed had been planted. Maybe I shouldn't believe everything I think." | "种子已经播种了。 也许我不应该相信我所想的一切。" | OK | Faithful. |
| 51 | "Headset. off." | "耳机。关闭。" | minor | Stage-direction literal; "摘下耳机。" reads naturally. |
| 52 | "To take it off, I just had to realize I had it on. Ropes broken." | "为了把它脱下来，我必须意识到我穿着它。 绳子断了。" | minor | "just" dropped; "Ropes broken" → "绳子断了" (the ropes broke) rather than "绳索已挣脱". |
| 53 | "New beliefs lead to new actions." | "新的信念导致新的行动。" | minor | "导致" has a negative connotation; "带来" is neutral. Rest faithful. |
| 54 | "took on various side projects. saying yes to ones ..." | "承担了各种副业。对那些 ... 项目说好。" | minor | "副业" for side projects; "说好" literal for "saying yes". |
| 55 | "trusting I could figure it out." | "相信我能弄清楚。" | OK | Faithful. |
| 56 | "I was still afraid of failure and taking wrong turns. And sometimes I did." | "我仍然害怕失败和走错弯路。 有时我做到了。" | **major** | "And sometimes I did" (sometimes I did take wrong turns) → "有时我做到了" ("sometimes I succeeded"), reversing the admission. Minor: "走错弯路" is redundant. |
| 57 | "I just no longer let this stop me." | "我只是不再让这阻止我。" | OK | Faithful. |
| 58 | "a 10 week part time position coaching speakers." | "担任了为期10周的兼职职位，担任教练演讲者。" | **major** | "coaching speakers" (coaching/teaching speakers) → "担任教练演讲者" ("served as a coach speaker"), garbling the role. Should be "担任演讲教练/指导演讲者". |
| 59 | "We're talking Fernando level love." | "我们谈论的是费尔南多级别的爱。" | minor | Idiomatic "we're talking..." rendered literally; understandable but flat. |
| 60 | "No longer afraid to grab things with both hands." | "不再害怕用双手抓东西。" | minor | Idiom literalized; "全力抓住机会" would carry the sense. Rest faithful. |
| 61 | "Particularly meaningful for me is I now get to give others what I to lost for so long." | "对我来说特别有意义的是，我现在可以把我失去这么久的东西给别人。" | minor + SD-A minor | ASR "that" dropped and "I'd" → "I to"; translation recovers "我失去这么久的". Slightly awkward but faithful. |
| 62 | "A more powerful voice." | "一个更有力量的声音。" | OK | Faithful. |
| 63 | "When I was self conscious and shy ... on a TedED stage." | "当我自我意识和害羞的时候 ... 在TedED舞台上 ..." | minor + SD-A minor | "self-conscious" → "自我意识" (self-awareness) false friend; should be "难为情/不自在". SD-A: "TED" → "TedED"; translation keeps the wrong brand. |
| 64 | "That would have sounded more like a bad dream. Yet somehow Here I am." | "那听起来更像是一场噩梦。 然而，不知怎的，我在这里。" | minor | Conditional "would have sounded" loses "会"; "bad dream" → "噩梦" strengthens slightly. |
| 65 | "Each new thought, each new action built on the one before it ..." | "每一个新想法，每一个新行动都建立在之前的行动之上 ..." | minor | "the one before it" becomes "之前的行动" (the previous action), narrowing thought/action to action. |
| 66 | "I still have ropes. I'm working to break. My goal is fewer over time." | "我还有绳子。 我正在努力休息。 随着时间的推移，我的目标是减少。" | **critical** | "I'm working to break [them]" → "我正在努力休息" ("I'm working hard to rest"): the key verb is mistranslated as "take a break". Minor: "减少" drops "fewer ropes". |
| 67 | "To get there, myself of the marshmallow challenge." | "为了到达那里，我自己挑战棉花糖。" | **critical** + SD-A major | Translation fabricates "我自己挑战棉花糖" ("I challenge the marshmallow"); the intended "I remind myself of the marshmallow challenge" is lost. SD-A: "I remind" was dropped; the volatile max 36 chars exactly matches the retained "myself of the marshmallow challenge." and no event contains the missing words. |
| 68 | "20 sticks of spaghetti, a yard of string ... tallest freestanding tower ..." | "20根意大利面条、一码绳子 ... 最高的独立塔 ..." | minor | "freestanding" → "独立塔" (could read "independent tower"); "they can" omitted. Numbers correct. |
| 69 | "The marshmallow has to be on top." | "棉花糖必须放在上面。" | OK | Faithful. |
| 70 | "Who do you think are among the top performers?" | "你认为谁是表现最好的人？" | minor | "among the top performers" (one of the best) → "表现最好的人" (the best), dropping "among". |
| 71 | "Recent graduates. of, of kindergarten" | "幼儿园的应届毕业生" | minor + SD-A minor | ASR stutter "of, of"; "应届毕业生" is a college-graduate term applied to kindergarten, but faithful to source. |
| 72 | "The other groups will take what they think they know ... executing in the wrong direction." | "其他小组会采取他们认为自己知道的东西 ... 朝着错误的方向执行。" | minor | "采取...东西" awkward; "执行" lacks an object; meaning mostly preserved. |
| 73 | "In contrast, kindergartners stay open to multiple possibilities." | "相比之下，幼儿园的人对多种可能性持开放态度。" | minor | "kindergartners" → "幼儿园的人" instead of "幼儿园的孩子/学生". SD-A cosmetic spelling. |
| 74 | "They have fun." | "他们玩得很开心。" | OK | Faithful. |
| 75 | "What makes us so amazing as children is we live in a world before ropes." | "作为孩子，我们如此神奇的是，我们生活在一个绳索之前的世界。" | minor | Ungrammatical Chinese ("我们如此神奇的是"); meaning inferable. |
| 76 | "in a world before what's known. when there is what's possible, in a world before I can't. When there is, how could I?" | "在一个已知之前的世界里。当有可能的时候，在一个我不能之前的世界里。 当有的时候，我怎么可能呢？" | **major** | The quoted parallel "what's known / what's possible / I can't / how could I?" is literalized into ungrammatical fragments; "当有的时候，我怎么可能呢？" changes the rhetorical meaning. |
| 77 | "In a world before falling and staying down ... undeterred." | "在一个跌倒和停留之前的世界里 ... 毫不畏懼。" | minor | "staying down" → "停留" loses "down"; traditional 懼 in simplified text. Rest faithful. |
| 78 | "What the design class was for me, I hope this talk is for you." | "设计课对我来说是什么，我希望这次演讲是为你准备的。" | **major** | Intended "I hope this talk does for you what the design class did for me"; translation reads "I hope this talk was prepared for you", losing the parallel. |
| 79 | "A seed. that gets you to question what you've previously accepted as true." | "一颗种子。让你质疑你以前接受为事实的东西。" | minor | "接受为事实" is slightly literal; "信以为真" is natural. Meaning preserved. |
| 80 | "That makes you more aware of your ropes." | "这让你更清楚自己的绳索。" | OK | Faithful. |
| 81 | "that helps you see, they were always yours to bring." | "这有助于你看到，它们一直都是你带来的。" | **SD-A major** + minor | Ground truth "yours to break"; ASR misheard "break" as "bring", and translation renders "你带来的" ("brought by you"), inverting the closing metaphor. Translation is faithful to the defective source; the semantic result is wrong. |
| 82 | "No matter who you are ... in this moment. If you break your ropes." | "无论你是谁，或者你此刻在哪里。 如果你断了绳子。" | **SD-X critical** + minor | Assembler dropped "there is the life that you can be living"; the row has no main assertion, only two fragments. Diagnostics: 41-char volatile at range 766.91–770.86 (16:32:35.5) exactly matches the missing clause; no final for that range; row text is 54-char first phrase + 25-char final. Prior `fix-full-final` row 82 retained "There is the life that you can be living." Minor: "断了绳子" (ropes broke) vs "你挣脱绳索". |
| 83 | "You get there one new thought at a time. One new action at a time. one day ..." | "你一次一个新想法到达那里。 一次一个新的行动。有一天 ..." | minor + SD-A minor | Word order awkward; "一次一个新的行动。" is a fragment; ASR dropped "until", so the "until one day" relation is lost. |

## Source defects vs ground truth (ASR vs assembler)

### Assembler (words recognized, then dropped)
- **Row 82 — confirmed assembler.** Utterance `57B60D7B…`: volatile range 757.97 + 8.94 s reached 54 chars ("No matter who you are or where you are, in this moment."); final 40 chars @ 761.03 + 5.70; then volatile range 766.91 + 3.95 s reached 41 chars, matching "there is the life that you can be living" (40) with **no final**; next range 769.91 + 3.04 s final 25 chars ("If you break your ropes."). The stored row is 79 chars = 54 + space + 24, so the 41-char middle phrase was recognized and dropped. `fix-full-final` row 82 contains the missing clause, so this is a regression in the run under review.

### ASR (final text itself lacks/wrong words; no volatile evidence of the lost words)
- **Rows 0/1 boundary — "white men" deleted** (GT cue 142 "white men perform better"). No diagnostics for rows 0–4 (ring evicted); the same omission appears in all three earlier runs, so **likely ASR**, not a new assembler drop.
- **Row 1** — "it'd" → "it's" (no meaning change).
- **Row 7** — "Cameron Russell" → "Cameron Rushell" (name).
- **Row 8** — "Lidia Yuknavitch shared" → "Lydia Yuknovic share"; "and" → "an"; "the" dropped.
- **Row 13** — "I'd" → "I've" (tense/conditional reading).
- **Row 17** — "she's" → "he's" (friend's gender; translation uses 他).
- **Row 21** — "he's" → "you's"; "would" → "will".
- **Row 22** — "him" → "them".
- **Row 23** — "friends'" → "friends's".
- **Row 24** — "past" → "pastor" (fabricates a pastor relationship).
- **Row 30** — "participants'" → "participants's".
- **Row 38** — "thinking" → "thinkinging" (stutter).
- **Row 41** — "you" inserted ("no one to look to you for the answers").
- **Row 43** — "designs" → "Dess" (word truncated; translation leaves it untranslated).
- **Row 44** — "were the" deleted (sentence fragment).
- **Row 49** — "were" → "of".
- **Row 61** — "that" deleted; "I'd" → "I to".
- **Row 63** — "TED" → "TedED".
- **Row 67** — "I remind" deleted. Volatile max 36 chars exactly matches the retained "myself of the marshmallow challenge."; no event contains "I remind". **ASR.**
- **Row 71** — "of" duplicated (stutter).
- **Row 73** — "kindergarteners" → "kindergartners" (cosmetic).
- **Row 81** — "break" → "bring" (meaning-changing).
- **Row 83** — "until" deleted. Second phrase max/final 26 chars = "One new action at a time." (25 + punctuation), no room for "until" (30 with it). **Likely ASR.**

## Cross-row properties
1. **Rows 0–1: missing subject creates an apparent duplicate.** Row 0 ends "performance...diagnostic of sports intelligence."; row 1 starts "表现更好。" Both rows contain "perform better", but the second is the white-men clause missing "white men". A listener sees a repeated "表现更好" with no new subject; the white-men/black-men contrast is lost. This is a source defect, not a duplicated translation.
2. **Rows 21–22: pronoun chain breaks.** ASR "you's"/"them" vs ground-truth "he's"/"him" means the translation alternates 你 → 他 and 他们 → 他. The three-branch reasoning ("moving too fast / feeling rejected") becomes incoherent about who is feeling what.
3. **Rows 24–25: false cause survives.** Row 24 says "牧师的关系" (pastor relationship); row 25 says "这不是任何人猜到的" but never identifies the real cause (a past relationship). The listener is left with a fabricated pastor explanation.
4. **Row 48: translation is a stale partial, not the settled row.** The final translation job failed (`corruptedOutput`, seq 974), and the stored text is a prefix ending "很解放了，". Row 49 ("我想知道...") does not recover "困惑"; the omission is visible to the listener.
5. **Row 66–67: split sentence loses the rope metaphor.** "I still have ropes. I'm working to break." is split by ASR punctuation; the translation renders "break" as "休息", and row 67's "To get there..." then has no coherent antecedent.
6. **Row 67–68: missing "I remind" breaks the transition.** Row 67 fabricates "我自己挑战棉花糖"; row 68 then describes the marshmallow challenge, but the listener was never told the speaker is reminding herself of it.
7. **Row 81–82: adjacent rows disagree about the rope metaphor.** Row 81 says "yours to bring" (你带来的); row 82 says "If you break your ropes" (你断了绳子). The closing call to "break your ropes" is undermined by the preceding "bring".
8. **Row 82–83: missing main clause leaves "there" without antecedent.** Row 83 begins "You get there..."; the intended "there" is the life described in the clause that was dropped.
9. **Terminology inconsistency:** "beliefs" is 信仰 (rows 2, 4, 28) and 信念 (rows 2 second sentence, 15, 53). The first is the wrong sense; the inconsistency itself is visible.
10. **No genuine duplicated clauses.** The repeated "I had to" (rows 40–42), "In a world before" (rows 75–77), and "他猜测他可能" (rows 17–18) are source rhetoric/anaphora. Multi-sentence rows are allowed by the range-gap policy and were not flagged by themselves.

## Counts
- **Critical:** 5 findings across 4 rows/boundaries — translation rows 33, 66, 67 (3) + source defects row 0/1 boundary and row 82 (2).
- **Major:** 15 findings — translation rows 8, 17, 21, 22, 23, 24, 41, 42, 43, 48, 56, 58, 76, 78 (14) + source row 81 (1). Rows 17, 21, 22, 24, 41, 43, 67 also carry major ASR defects (counted once at row level).
- **Minor:** 38 rows (style/terminology/particles); many also carry cosmetic ASR defects.
- **OK:** 25 rows with no semantic issue found.
- **Source-defect rows:** 24 total — 23 ASR (2 meaning-critical/major groups, 21 cosmetic-to-moderate) + 1 assembler (row 82). The 23 ASR rows are listed above; the assembler row is row 82.
- Mechanical score is not the gating metric: 84/84 translated, sourceCoverage 0.988, WER 2.64%, yet 3 critical translation errors and a confirmed assembler clause loss.

## Bottom line
**FAIL for a reasonable P1-1 semantic signoff.** The run is mechanically complete (84/84 rows, 0 empty translations) and the source coverage is high, but it contains:
- a **confirmed assembler drop** (row 82: "there is the life that you can be living"), which is a regression vs the earlier `fix-full-final` run;
- a **critical ASR omission** at the row 0/1 boundary ("white men"), leaving row 1 subjectless and destroying the white-men/black-men contrast;
- **3 critical translation errors** (rows 33, 66, 67) and **14 major translation errors**, including a reproducible final-translation failure on row 48 that drops "confused".

**Blocking rows:** 82 (assembler), 0/1 (white men), 33, 66, 67, 48, 24, 17, 21, 22, 23, 41, 42, 43, 56, 58, 76, 78, 81. If the signoff scope is strictly the assembler/content-preservation layer, row 82 alone blocks; rows 0/1 and 81 are ASR-side and should be tracked separately. The translation-layer rows (33, 66, 67, 48, etc.) block any end-to-end semantic quality bar regardless.
