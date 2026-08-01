#!/usr/bin/env bash
# テスト用 assert ヘルパー。各 test_*.sh から source する。

TESTS=0
FAILED=0

assert_eq() { # <実際> <期待> <説明>
  TESTS=$((TESTS + 1))
  if [ "$1" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s\n       期待: [%s]\n       実際: [%s]\n' "$3" "$2" "$1"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() { # <全体> <含まれるべき部分文字列> <説明>
  TESTS=$((TESTS + 1))
  case "$1" in
    *"$2"*) printf '  ok   %s\n' "$3" ;;
    *)
      printf '  FAIL %s\n       含まれるべき: [%s]\n       実際: [%s]\n' "$3" "$2" "$1"
      FAILED=$((FAILED + 1))
      ;;
  esac
}

assert_not_contains() { # <全体> <含まれてはいけない部分文字列> <説明>
  TESTS=$((TESTS + 1))
  case "$1" in
    *"$2"*)
      printf '  FAIL %s\n       含まれてはいけない: [%s]\n       実際: [%s]\n' "$3" "$2" "$1"
      FAILED=$((FAILED + 1))
      ;;
    *) printf '  ok   %s\n' "$3" ;;
  esac
}

assert_status() { # <実際の終了コード> <期待する終了コード> <説明>
  assert_eq "$1" "$2" "$3"
}

finish() {
  printf '  --- %d 件中 %d 件失敗\n' "$TESTS" "$FAILED"
  [ "$FAILED" -eq 0 ]
}
