/** @file
  BaConfig.c -- bootanim.cfg 解析器（纯逻辑，可脱离 UEFI 做单元测试）。

  格式：键=值 的纯文本，UTF-8（可带 BOM），行尾 CRLF/LF 均可，
  '#' 或 ';' 起始的行为注释，未知键被忽略（保证向前兼容）。

  Copyright (c) 2024. SPDX-License-Identifier: GPL-3.0-or-later
**/

#include "Ba.h"

/* ------------------------------------------------------------------ */
/* 默认值                                                             */
/* ------------------------------------------------------------------ */
void
BaConfigDefault (
  BA_CONFIG *Cfg
  )
{
  if (Cfg == BA_NULL) {
    return;
  }

  BaMemSet (Cfg, 0, sizeof (BA_CONFIG));

  /* 默认什么都不指定：由主程序去探测 <程序目录>\anim.baa */
  Cfg->Anim[0] = 0;

  BaStrCopyA16 (Cfg->Chainload, BA_PATH_MAX, "\\EFI\\Microsoft\\Boot\\bootmgfw-orig.efi");
  BaStrCopyA16 (Cfg->ChainloadFallback, BA_PATH_MAX, "\\EFI\\Microsoft\\Boot\\bootmgfw.efi");

  Cfg->Frames      = 0;
  Cfg->Enabled     = 1;       /* 1 = 正常播放；0 = 直接交回引导程序 */
  Cfg->Fps         = 0;       /* 0 = 使用 .baa 头里的 fps，再不行 30 */
  Cfg->Loop        = 1;       /* 默认只播一遍 */
  Cfg->Pacing      = BA_PACING_AUTO;
  Cfg->Scale       = BA_SCALE_FIT;
  Cfg->Filter      = BA_FILTER_AUTO;
  Cfg->Background  = 0x00000000u;  /* 黑 */
  Cfg->TimeoutMs   = 15000;   /* 安全上限：任何情况下最多占用 15 秒 */
  Cfg->LeadInMs    = 0;
  Cfg->SkipKey     = 1;
  Cfg->Debug       = 0;
  Cfg->ClearFirst  = 1;
  Cfg->VideoWidth  = 0;
  Cfg->VideoHeight = 0;
}

/* ------------------------------------------------------------------ */
/* 解析辅助                                                           */
/* ------------------------------------------------------------------ */
static BA_BOOL
BaIsSpace (
  char C
  )
{
  return (BA_BOOL)((C == ' ') || (C == '\t') || (C == '\r') || (C == '\n') || (C == '\f') || (C == '\v'));
}

static BA_BOOL
BaIsDigit (
  char C
  )
{
  return (BA_BOOL)((C >= '0') && (C <= '9'));
}

static char
BaUpper (
  char C
  )
{
  if ((C >= 'a') && (C <= 'z')) {
    return (char)(C - 'a' + 'A');
  }
  return C;
}

static BA_BOOL
BaKeyIs (
  const char *Key,
  BA_SIZE     KeyLen,
  const char *Want
  )
{
  BA_SIZE I;

  for (I = 0; I < KeyLen; I++) {
    if (Want[I] == 0) {
      return BA_FALSE;
    }
    if (BaUpper (Key[I]) != BaUpper (Want[I])) {
      return BA_FALSE;
    }
  }
  return (BA_BOOL)(Want[KeyLen] == 0);
}

static BA_BOOL
BaValEq (
  const char *Val,
  BA_SIZE     Len,
  const char *Want
  )
{
  return BaKeyIs (Val, Len, Want);
}

static BA_BOOL
BaParseU32 (
  const char *Val,
  BA_SIZE     Len,
  BA_U32     *Out
  )
{
  BA_U64  V = 0;
  BA_SIZE I = 0;
  BA_BOOL Hex = BA_FALSE;

  if ((Val == BA_NULL) || (Len == 0)) {
    return BA_FALSE;
  }
  if ((Len >= 2) && (Val[0] == '0') && ((Val[1] == 'x') || (Val[1] == 'X'))) {
    Hex = BA_TRUE;
    I = 2;
    if (Len == 2) {
      return BA_FALSE;
    }
  }
  for (; I < Len; I++) {
    BA_U32 D;
    char  C = Val[I];

    if (Hex) {
      if ((C >= '0') && (C <= '9')) {
        D = (BA_U32)(C - '0');
      } else if ((C >= 'a') && (C <= 'f')) {
        D = (BA_U32)(C - 'a' + 10);
      } else if ((C >= 'A') && (C <= 'F')) {
        D = (BA_U32)(C - 'A' + 10);
      } else {
        return BA_FALSE;
      }
      V = (V << 4) | (BA_U64)D;
    } else {
      if (!BaIsDigit (C)) {
        return BA_FALSE;
      }
      D = (BA_U32)(C - '0');
      V = V * 10u + (BA_U64)D;
    }
    if (V > 0xFFFFFFFFu) {
      return BA_FALSE;   /* 溢出保护（BA_U64 累加，不会真的溢出） */
    }
  }

  *Out = (BA_U32)V;
  return BA_TRUE;
}

/* 十六进制颜色 "RRGGBB" 或 "#RRGGBB" -> 0x00RRGGBB */
static BA_BOOL
BaParseColor (
  const char *Val,
  BA_SIZE     Len,
  BA_U32     *Out
  )
{
  BA_U32  V = 0;
  BA_SIZE I;

  if ((Val == BA_NULL) || (Out == BA_NULL)) {
    return BA_FALSE;
  }
  if ((Len > 0) && (Val[0] == '#')) {
    Val++;
    Len--;
  }
  if (Len != 6) {
    return BA_FALSE;
  }
  for (I = 0; I < Len; I++) {
    char  C = Val[I];
    BA_U32 D;

    if ((C >= '0') && (C <= '9')) {
      D = (BA_U32)(C - '0');
    } else if ((C >= 'a') && (C <= 'f')) {
      D = (BA_U32)(C - 'a' + 10);
    } else if ((C >= 'A') && (C <= 'F')) {
      D = (BA_U32)(C - 'A' + 10);
    } else {
      return BA_FALSE;
    }
    V = (V << 4) | D;
  }

  *Out = V & 0x00FFFFFFu;
  return BA_TRUE;
}

/* ------------------------------------------------------------------ */
/* 主解析                                                             */
/* ------------------------------------------------------------------ */
BA_STATUS
BaConfigParse (
  const char  *Text,
  BA_SIZE      Len,
  BA_CONFIG   *Cfg
  )
{
  BA_SIZE Pos = 0;

  if ((Text == BA_NULL) || (Cfg == BA_NULL)) {
    return BA_ERR_INVALID;
  }

  /* 跳过 UTF-8 BOM */
  if ((Len >= 3) &&
      ((unsigned char)Text[0] == 0xEF) &&
      ((unsigned char)Text[1] == 0xBB) &&
      ((unsigned char)Text[2] == 0xBF))
  {
    Pos = 3;
  }

  while (Pos < Len) {
    BA_SIZE     LineStart = Pos;
    BA_SIZE     LineEnd;
    BA_SIZE     Eq = (BA_SIZE)-1;
    BA_SIZE     I;
    const char *Key;
    BA_SIZE     KeyLen;
    const char *Val;
    BA_SIZE     ValLen;
    BA_U32      Num = 0;

    /* 找行尾 */
    while ((Pos < Len) && (Text[Pos] != '\n')) {
      Pos++;
    }
    LineEnd = Pos;
    if (Pos < Len) {
      Pos++;   /* 跳过 '\n' */
    }

    /* 去掉行尾的 '\r' */
    while ((LineEnd > LineStart) && (Text[LineEnd - 1] == '\r')) {
      LineEnd--;
    }

    /* 去掉行首空白 */
    while ((LineStart < LineEnd) && BaIsSpace (Text[LineStart])) {
      LineStart++;
    }
    /* 去掉行尾空白 */
    while ((LineEnd > LineStart) && BaIsSpace (Text[LineEnd - 1])) {
      LineEnd--;
    }
    if (LineStart >= LineEnd) {
      continue;   /* 空行 */
    }
    if ((Text[LineStart] == '#') || (Text[LineStart] == ';')) {
      continue;   /* 注释 */
    }

    /* 找第一个 '=' */
    for (I = LineStart; I < LineEnd; I++) {
      if (Text[I] == '=') {
        Eq = I;
        break;
      }
    }
    if (Eq == (BA_SIZE)-1) {
      continue;   /* 没有 '=' 的行忽略 */
    }

    Key    = &Text[LineStart];
    KeyLen = Eq - LineStart;
    while ((KeyLen > 0) && BaIsSpace (Key[KeyLen - 1])) {
      KeyLen--;   /* 键名尾部空白 */
    }

    Val    = &Text[Eq + 1];
    ValLen = LineEnd - (Eq + 1);
    while ((ValLen > 0) && BaIsSpace (Val[0])) {
      Val++;
      ValLen--;
    }
    while ((ValLen > 0) && BaIsSpace (Val[ValLen - 1])) {
      ValLen--;
    }

    if (KeyLen == 0) {
      continue;
    }

    /* ---- 字符串型 ---- */
    if (BaKeyIs (Key, KeyLen, "ANIM") ||
        BaKeyIs (Key, KeyLen, "ANIMATION") ||
        BaKeyIs (Key, KeyLen, "FRAMES_FILE"))
    {
      BaUtf8ToUtf16 (Cfg->Anim, BA_PATH_MAX, Val, ValLen);
      continue;
    }
    if (BaKeyIs (Key, KeyLen, "CHAINLOAD") ||
        BaKeyIs (Key, KeyLen, "CHAIN") ||
        BaKeyIs (Key, KeyLen, "BOOT"))
    {
      BaUtf8ToUtf16 (Cfg->Chainload, BA_PATH_MAX, Val, ValLen);
      continue;
    }
    if (BaKeyIs (Key, KeyLen, "CHAINLOAD_FALLBACK") ||
        BaKeyIs (Key, KeyLen, "CHAIN_FALLBACK"))
    {
      BaUtf8ToUtf16 (Cfg->ChainloadFallback, BA_PATH_MAX, Val, ValLen);
      continue;
    }

    /* ---- 枚举型 ---- */
    if (BaKeyIs (Key, KeyLen, "ENABLED") || BaKeyIs (Key, KeyLen, "ENABLE") ||
        BaKeyIs (Key, KeyLen, "ACTIVE"))
    {
      if (BaValEq (Val, ValLen, "0") || BaValEq (Val, ValLen, "off") ||
          BaValEq (Val, ValLen, "no") || BaValEq (Val, ValLen, "false") ||
          BaValEq (Val, ValLen, "disable") || BaValEq (Val, ValLen, "disabled"))
      {
        Cfg->Enabled = 0;
      } else {
        Cfg->Enabled = 1;
      }
      continue;
    }
    if (BaKeyIs (Key, KeyLen, "PACING") || BaKeyIs (Key, KeyLen, "TIMING")) {
      if (BaValEq (Val, ValLen, "fixed") || BaValEq (Val, ValLen, "stall")) {
        Cfg->Pacing = BA_PACING_FIXED;
      } else if (BaValEq (Val, ValLen, "off") || BaValEq (Val, ValLen, "none") ||
                 BaValEq (Val, ValLen, "max") || BaValEq (Val, ValLen, "fast"))
      {
        Cfg->Pacing = BA_PACING_OFF;
      } else {
        Cfg->Pacing = BA_PACING_AUTO;
      }
      continue;
    }
    if (BaKeyIs (Key, KeyLen, "SCALE") || BaKeyIs (Key, KeyLen, "SCALING")) {
      if (BaValEq (Val, ValLen, "native") || BaValEq (Val, ValLen, "1to1")) {
        Cfg->Scale = BA_SCALE_NATIVE;
      } else if (BaValEq (Val, ValLen, "fit") || BaValEq (Val, ValLen, "contain")) {
        Cfg->Scale = BA_SCALE_FIT;
      } else if (BaValEq (Val, ValLen, "fill") || BaValEq (Val, ValLen, "cover")) {
        Cfg->Scale = BA_SCALE_FILL;
      } else if (BaValEq (Val, ValLen, "stretch")) {
        Cfg->Scale = BA_SCALE_STRETCH;
      } else if (BaValEq (Val, ValLen, "center") || BaValEq (Val, ValLen, "centre")) {
        Cfg->Scale = BA_SCALE_CENTER;
      }
      continue;
    }
    if (BaKeyIs (Key, KeyLen, "FILTER") || BaKeyIs (Key, KeyLen, "RESAMPLE")) {
      if (BaValEq (Val, ValLen, "auto")) {
        Cfg->Filter = BA_FILTER_AUTO;
      } else if (BaValEq (Val, ValLen, "nearest") || BaValEq (Val, ValLen, "point")) {
        Cfg->Filter = BA_FILTER_NEAREST;
      } else if (BaValEq (Val, ValLen, "bilinear") || BaValEq (Val, ValLen, "linear")) {
        Cfg->Filter = BA_FILTER_BILINEAR;
      }
      continue;
    }
    if (BaKeyIs (Key, KeyLen, "SKIP_KEY") || BaKeyIs (Key, KeyLen, "SKIPKEY")) {
      /* 既接受 0/1，也接受 any/on/off/none 这类写法 */
      if (BaValEq (Val, ValLen, "none") || BaValEq (Val, ValLen, "off") ||
          BaValEq (Val, ValLen, "no") || BaValEq (Val, ValLen, "false") ||
          BaValEq (Val, ValLen, "disable") || BaValEq (Val, ValLen, "0"))
      {
        Cfg->SkipKey = 0;
      } else {
        Cfg->SkipKey = 1;
      }
      continue;
    }

    /* ---- 颜色 ---- */
    if (BaKeyIs (Key, KeyLen, "BACKGROUND") || BaKeyIs (Key, KeyLen, "BG")) {
      if (BaParseColor (Val, ValLen, &Num)) {
        Cfg->Background = Num;
      }
      continue;
    }

    /* ---- 视频模式 WxH ---- */
    if (BaKeyIs (Key, KeyLen, "VIDEO_MODE") || BaKeyIs (Key, KeyLen, "RESOLUTION")) {
      BA_SIZE P;
      BA_BOOL Found = BA_FALSE;

      if (BaValEq (Val, ValLen, "auto") || BaValEq (Val, ValLen, "current") ||
          BaValEq (Val, ValLen, "keep") || BaValEq (Val, ValLen, "native") ||
          BaValEq (Val, ValLen, "default"))
      {
        Cfg->VideoWidth  = 0;
        Cfg->VideoHeight = 0;
        continue;
      }
      for (P = 0; P < ValLen; P++) {
        if ((Val[P] == 'x') || (Val[P] == 'X')) {
          BA_U32 W = 0;
          BA_U32 H = 0;
          if (BaParseU32 (Val, P, &W) && BaParseU32 (Val + P + 1, ValLen - P - 1, &H)) {
            Cfg->VideoWidth  = W;
            Cfg->VideoHeight = H;
            Found = BA_TRUE;
          }
          break;
        }
      }
      if (!Found) {
        Cfg->VideoWidth  = 0;
        Cfg->VideoHeight = 0;
      }
      continue;
    }

    /* ---- 数值型 ---- */
    if (!BaParseU32 (Val, ValLen, &Num)) {
      continue;   /* 值不合法：忽略该键，保持默认 */
    }
    if (BaKeyIs (Key, KeyLen, "FRAMES") || BaKeyIs (Key, KeyLen, "FRAME_COUNT")) {
      Cfg->Frames = Num;
    } else if (BaKeyIs (Key, KeyLen, "FPS")) {
      Cfg->Fps = Num;
    } else if (BaKeyIs (Key, KeyLen, "LOOP") || BaKeyIs (Key, KeyLen, "REPEAT")) {
      Cfg->Loop = Num;
    } else if (BaKeyIs (Key, KeyLen, "TIMEOUT_MS") || BaKeyIs (Key, KeyLen, "TIMEOUT")) {
      Cfg->TimeoutMs = Num;
    } else if (BaKeyIs (Key, KeyLen, "LEAD_IN_MS") || BaKeyIs (Key, KeyLen, "LEADIN")) {
      Cfg->LeadInMs = Num;
    } else if (BaKeyIs (Key, KeyLen, "SKIP_KEY") || BaKeyIs (Key, KeyLen, "SKIPKEY")) {
      Cfg->SkipKey = Num;
    } else if (BaKeyIs (Key, KeyLen, "DEBUG")) {
      Cfg->Debug = Num;
    } else if (BaKeyIs (Key, KeyLen, "CLEAR_FIRST") || BaKeyIs (Key, KeyLen, "CLEAR")) {
      Cfg->ClearFirst = Num;
    }
    /* 其余未知键静默忽略 */
  }

  /* ---- 一致性收敛 ---- */
  if (Cfg->Fps > 240) {
    Cfg->Fps = 240;
  }
  if (Cfg->Loop > 1000) {
    Cfg->Loop = 1000;
  }
  if (Cfg->Scale > BA_SCALE_CENTER) {
    Cfg->Scale = BA_SCALE_FIT;
  }
  if (Cfg->Filter > BA_FILTER_BILINEAR) {
    Cfg->Filter = BA_FILTER_AUTO;
  }
  if (Cfg->Pacing > BA_PACING_OFF) {
    Cfg->Pacing = BA_PACING_AUTO;
  }
  /* 视频模式必须是两个都有效或者都不指定 */
  if ((Cfg->VideoWidth == 0) || (Cfg->VideoHeight == 0)) {
    Cfg->VideoWidth  = 0;
    Cfg->VideoHeight = 0;
  }

  return BA_OK;
}
