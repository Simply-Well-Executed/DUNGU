$source = @'
using System;
using System.Collections.Generic;

namespace Dungu
{
    public sealed class BidiAuditIssue
    {
        public string Code { get; private set; }
        public string Control { get; private set; }
        public int CodePointOffset { get; private set; }
        public int ByteOffset { get; private set; }
        public int Line { get; private set; }
        public string Message { get; private set; }

        internal BidiAuditIssue(string code, string control, int codePointOffset, int byteOffset, int line, string message)
        {
            Code = code;
            Control = control;
            CodePointOffset = codePointOffset;
            ByteOffset = byteOffset;
            Line = line;
            Message = message;
        }
    }

    public sealed class BidiAuditReport
    {
        public bool Balanced { get; private set; }
        public int OpenCount { get; private set; }
        public int CloseCount { get; private set; }
        public int MaximumDepth { get; private set; }
        public BidiAuditIssue[] Issues { get; private set; }

        internal BidiAuditReport(int openCount, int closeCount, int maximumDepth, List<BidiAuditIssue> issues)
        {
            OpenCount = openCount;
            CloseCount = closeCount;
            MaximumDepth = maximumDepth;
            Issues = issues.ToArray();
            Balanced = Issues.Length == 0;
        }
    }

    public sealed class InvalidUnicodeException : Exception
    {
        public int Utf16Offset { get; private set; }

        internal InvalidUnicodeException(int utf16Offset)
            : base("Input contains an unpaired UTF-16 surrogate at code-unit offset " + utf16Offset + ".")
        {
            Utf16Offset = utf16Offset;
        }
    }

    public static class BidiIsolateAudit
    {
        private sealed class Opening
        {
            public string Control;
            public int CodePointOffset;
            public int ByteOffset;
            public int Line;
        }

        public static BidiAuditReport Analyze(string text)
        {
            if (text == null)
                throw new ArgumentNullException("text");

            var issues = new List<BidiAuditIssue>();
            var stack = new List<Opening>();
            int openCount = 0;
            int closeCount = 0;
            int maximumDepth = 0;
            int codePointOffset = 0;
            int byteOffset = 0;
            int line = 1;
            int utf16Offset = 0;
            bool previousWasCR = false;

            while (utf16Offset < text.Length)
            {
                int codePoint;
                int utf16Length;
                ReadCodePoint(text, utf16Offset, out codePoint, out utf16Length);

                if (codePoint == 0x000A && previousWasCR)
                {
                    previousWasCR = false;
                }
                else if (IsLineBreak(codePoint))
                {
                    for (int index = stack.Count - 1; index >= 0; index--)
                    {
                        AddIssue(issues, "isolate-crosses-line", stack[index], "Isolate is not closed before a line break.");
                    }
                    stack.Clear();
                    line++;
                    previousWasCR = codePoint == 0x000D;
                }
                else
                {
                    previousWasCR = false;
                    switch (codePoint)
                    {
                        case 0x2066:
                            stack.Add(new Opening { Control = "LRI", CodePointOffset = codePointOffset, ByteOffset = byteOffset, Line = line });
                            openCount++;
                            break;
                        case 0x2067:
                            stack.Add(new Opening { Control = "RLI", CodePointOffset = codePointOffset, ByteOffset = byteOffset, Line = line });
                            openCount++;
                            break;
                        case 0x2068:
                            stack.Add(new Opening { Control = "FSI", CodePointOffset = codePointOffset, ByteOffset = byteOffset, Line = line });
                            openCount++;
                            break;
                        case 0x2069:
                            closeCount++;
                            if (stack.Count == 0)
                            {
                                issues.Add(new BidiAuditIssue(
                                    "unmatched-pdi",
                                    "PDI",
                                    codePointOffset,
                                    byteOffset,
                                    line,
                                    "PDI has no unmatched isolate opener on this line."));
                            }
                            else
                            {
                                stack.RemoveAt(stack.Count - 1);
                            }
                            break;
                    }

                    if (stack.Count > maximumDepth)
                        maximumDepth = stack.Count;
                }

                codePointOffset++;
                byteOffset += Utf8Length(codePoint);
                utf16Offset += utf16Length;
            }

            for (int index = stack.Count - 1; index >= 0; index--)
            {
                AddIssue(issues, "unclosed-isolate", stack[index], "Isolate is not closed before the end of input.");
            }

            return new BidiAuditReport(openCount, closeCount, maximumDepth, issues);
        }

        private static void ReadCodePoint(string text, int utf16Offset, out int codePoint, out int utf16Length)
        {
            char first = text[utf16Offset];
            if (Char.IsHighSurrogate(first))
            {
                if (utf16Offset + 1 >= text.Length || !Char.IsLowSurrogate(text[utf16Offset + 1]))
                    throw new InvalidUnicodeException(utf16Offset);

                codePoint = Char.ConvertToUtf32(first, text[utf16Offset + 1]);
                utf16Length = 2;
                return;
            }

            if (Char.IsLowSurrogate(first))
                throw new InvalidUnicodeException(utf16Offset);

            codePoint = first;
            utf16Length = 1;
        }

        private static int Utf8Length(int codePoint)
        {
            if (codePoint <= 0x7F)
                return 1;
            if (codePoint <= 0x7FF)
                return 2;
            if (codePoint <= 0xFFFF)
                return 3;
            return 4;
        }

        private static bool IsLineBreak(int codePoint)
        {
            return codePoint == 0x000D
                || codePoint == 0x000A
                || codePoint == 0x0085
                || codePoint == 0x2028
                || codePoint == 0x2029;
        }

        private static void AddIssue(List<BidiAuditIssue> issues, string code, Opening opening, string message)
        {
            issues.Add(new BidiAuditIssue(
                code,
                opening.Control,
                opening.CodePointOffset,
                opening.ByteOffset,
                opening.Line,
                message));
        }
    }
}
'@

if ($null -eq ('Dungu.BidiIsolateAudit' -as [type])) {
    Add-Type -TypeDefinition $source -ErrorAction Stop
}

function Invoke-DunguBidiAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    try {
        [Dungu.BidiIsolateAudit]::Analyze($Text)
    }
    catch [System.Management.Automation.MethodInvocationException] {
        if ($_.Exception.InnerException -is [Dungu.InvalidUnicodeException]) {
            throw $_.Exception.InnerException
        }
        throw
    }
}

Export-ModuleMember -Function Invoke-DunguBidiAudit
