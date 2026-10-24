#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成「多工作表 + 可推导关联」的 Excel 测试文件（第 50 轮追加）。

5 张工作表 = 5 张表（E-R 图上限），列名带 xxx_id，便于关系图按列名推导：
  users         id, name, email, created_at, active
  categories    id, name
  products      id, category_id, name, price          -> categories
  orders        id, user_id, status, created_at       -> users
  order_items   id, order_id, product_id, quantity, price
                -> orders / products（两列外键 = 多对多中间表）

用 DSH 自带 Python（openpyxl）生成，产物直接提交到 fixtures：
  PY=/Users/lyp/.dsh/dsh-runtimes/dsh-next-primary-runtime/dependencies/python/bin/python3
  $PY gen_relational_multi.py
"""
from __future__ import annotations

import datetime
import os

from openpyxl import Workbook

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "relational_multi.xlsx")

NOW = datetime.datetime(2026, 10, 1, 9, 30, 0)

USERS = [
    [1, "张伟", "zhangwei@example.com", NOW, True],
    [2, "李娜", "lina@example.com", NOW + datetime.timedelta(days=1), True],
    [3, "王强", "wangqiang@example.com", NOW + datetime.timedelta(days=2), False],
    [4, "赵敏", "zhaomin@example.com", NOW + datetime.timedelta(days=3), True],
    [5, "陈晨", "chenchen@example.com", NOW + datetime.timedelta(days=4), True],
]
CATEGORIES = [
    [1, "电子产品"],
    [2, "图书"],
    [3, "家居"],
    [4, "运动"],
]
PRODUCTS = [
    [1, 1, "机械键盘", 399.00],
    [2, 1, "无线鼠标", 129.50],
    [3, 1, "显示器", 1599.00],
    [4, 2, "数据库系统概念", 89.90],
    [5, 2, "Rust 程序设计", 128.00],
    [6, 3, "台灯", 159.00],
    [7, 3, "书架", 299.00],
    [8, 4, "跑步鞋", 469.00],
]
ORDERS = [
    [1, 1, "paid", NOW + datetime.timedelta(days=5)],
    [2, 1, "paid", NOW + datetime.timedelta(days=6)],
    [3, 2, "pending", NOW + datetime.timedelta(days=6)],
    [4, 3, "paid", NOW + datetime.timedelta(days=7)],
    [5, 4, "cancelled", NOW + datetime.timedelta(days=8)],
    [6, 5, "paid", NOW + datetime.timedelta(days=9)],
]
ORDER_ITEMS = [
    [1, 1, 1, 1, 399.00],
    [2, 1, 2, 2, 259.00],
    [3, 2, 4, 1, 89.90],
    [4, 2, 5, 1, 128.00],
    [5, 3, 6, 1, 159.00],
    [6, 3, 7, 1, 299.00],
    [7, 4, 3, 1, 1599.00],
    [8, 4, 8, 2, 938.00],
    [9, 5, 1, 1, 399.00],
    [10, 6, 2, 1, 129.50],
    [11, 6, 8, 1, 469.00],
    [12, 6, 6, 2, 318.00],
]

SHEETS = [
    ("users", ["id", "name", "email", "created_at", "active"], USERS),
    ("categories", ["id", "name"], CATEGORIES),
    ("products", ["id", "category_id", "name", "price"], PRODUCTS),
    ("orders", ["id", "user_id", "status", "created_at"], ORDERS),
    ("order_items", ["id", "order_id", "product_id", "quantity", "price"], ORDER_ITEMS),
]


def main() -> None:
    wb = Workbook()
    wb.remove(wb.active)
    for name, header, rows in SHEETS:
        ws = wb.create_sheet(title=name)
        ws.append(header)
        for row in rows:
            ws.append(row)
        ws.freeze_panes = "A2"
    wb.save(OUT)
    print("wrote", OUT, os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
