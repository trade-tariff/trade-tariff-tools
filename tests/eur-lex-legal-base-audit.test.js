import {
  buildLinks,
  celexGuess,
  needsBrowserCheck,
  ojCitation,
  toCsv,
} from '../scripts/eur-lex-legal-base-audit/rules.mjs';

describe('eur-lex legal base audit rules', () => {
  describe('celexGuess', () => {
    it.each([
      ['D9601421', '31996D0142'],
      ['D0203090', '32002D0309'],
      ['IYY99990', '320YYI9999'],
    ])('guesses the sector 3 CELEX id for %s', (rid, celex) => {
      expect(celexGuess(rid)).toBe(celex);
    });
  });

  describe('ojCitation', () => {
    it.each([
      ['L 35', 1, '1996-02-13', 'OJ.L_.1996.035.01.0001.01.ENG'],
      ['c 272', 5, '2010-10-08', 'OJ.C_.2010.272.01.0005.01.ENG'],
      ['C  87', 1, '2010-04-01', 'OJ.C_.2010.087.01.0001.01.ENG'],
      ['79', 41, '2007-03-23', null],
      ['L 263', null, '1978-09-27', null],
      ['C 003', 79, '2023-10-20', null],
      ['C 104', 1, null, null],
    ])('builds a citation from OJ %p page %p published %p', (number, page, publishedDate, citation) => {
      expect(ojCitation({
        officialjournal_number: number,
        officialjournal_page: page,
        published_date: publishedDate,
      })).toBe(citation);
    });
  });

  describe('buildLinks', () => {
    const candidates = [
      { rid: 'I0000010', celex: '32000I0001' },
      { rid: 'I0000020', celex: '32000I0002' },
      { rid: 'I0000030', celex: '32000I0003' },
      { rid: 'D0000040', celex: '32000D0004' },
      { rid: 'D0000050', celex: '32000D0005' },
      { rid: 'D0000060', celex: '32000D0006' },
      { rid: 'D0000070', celex: '32000D0007' },
    ];
    const browserPass = new Map([
      ['I0000010', 'OJ.C_.2000.001.01.0001.01.ENG'],
      ['I0000030', 'OJ.C_.2000.003.01.0001.01.ENG'],
      ['D0000040', 'OJ.L_.2000.004.01.0001.01.ENG'],
      ['D0000050', 'OJ.L_.2000.005.01.0001.01.ENG'],
    ]);
    const denylist = new Set(['I0000030']);
    const celexStatus = {
      '32000D0004': 303,
      '32000D0005': 404,
      '32000D0006': 404,
      '32000D0007': 303,
    };

    it('lists browser-verified citations and dead decisions, leaving working links out', () => {
      expect(buildLinks({ candidates, browserPass, denylist, celexStatus })).toEqual([
        { regulation_id: 'D0000050', oj_citation: 'OJ.L_.2000.005.01.0001.01.ENG' },
        { regulation_id: 'D0000060', oj_citation: null },
        { regulation_id: 'I0000010', oj_citation: 'OJ.C_.2000.001.01.0001.01.ENG' },
      ]);
    });

    it('refuses to run when a decision has no Cellar result', () => {
      const incomplete = { ...celexStatus, '32000D0006': undefined };

      expect(() => buildLinks({ candidates, browserPass, denylist, celexStatus: incomplete }))
        .toThrow('D0000060');
    });
  });

  describe('needsBrowserCheck', () => {
    const celexStatus = { '31996D0142': 404, '32002D0309': 303 };

    it.each([
      [['D0203090'], false],
      [['D9601421'], true],
      [['D9901010'], true],
      [['I1002720'], true],
      [['D0203090', 'I1002720'], true],
    ])('checks a citation for %p: %p', (rids, expected) => {
      expect(needsBrowserCheck({ rids }, celexStatus)).toBe(expected);
    });
  });

  describe('toCsv', () => {
    it('writes a blank citation as an empty field', () => {
      expect(toCsv([
        { regulation_id: 'D0000050', oj_citation: 'OJ.L_.2000.005.01.0001.01.ENG' },
        { regulation_id: 'D0000060', oj_citation: null },
      ])).toBe('regulation_id,oj_citation\nD0000050,OJ.L_.2000.005.01.0001.01.ENG\nD0000060,\n');
    });
  });
});
