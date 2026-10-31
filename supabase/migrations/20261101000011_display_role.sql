-- TWL WMS | Migration 011 | read-only 'display' role for the warehouse TV screen
alter type staff_role add value if not exists 'display';
